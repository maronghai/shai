#!/usr/bin/env bash
set -euo pipefail
WORK_DIR="$(dirname $0)"

AI_AGENT_VERSION="0.0.3"

$(curl -sS win/v1)
API_URL="${BASE_URL}/v1/chat/completions"


DATA_DIR="${WORK_DIR}/.data"
DB_PATH="$DATA_DIR/chat.db"
TOOLS_CACHE="$DATA_DIR/tools_cache.json"
TOOLS_DESC_CACHE="$DATA_DIR/tools_desc.txt"
MAX_HISTORY=40
TEMP_DIR="${WORK_DIR}/.tmp"
TOOLS_DIR="${WORK_DIR}/tools"
LAST_RESPONSE_FILE="${TEMP_DIR}/last-response.txt"
HISTFILE="$DATA_DIR/.input_history"
HISTFILESIZE=1000
HISTSIZE=1000

R='\033[0m'; B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'; D='\033[2m'

mkdir -p "$DATA_DIR" "$TEMP_DIR"

trap 'history -w 2>/dev/null || true' EXIT
trap 'echo; history -w 2>/dev/null || true; exit 0' INT

command -v sqlite3 >/dev/null 2>&1 || { echo "Error: sqlite3 is required" >&2; exit 1; }

SYSTEM_PROMPT="$(cat ${WORK_DIR}/SYSTEM_PROMPT.md)"

init_db() {
    if sqlite3 "$DB_PATH" "SELECT sql FROM sqlite_master WHERE type='table' AND name='messages' AND sql NOT LIKE '%tool_calls%'" 2>/dev/null | grep -q .; then
        sqlite3 "$DB_PATH" "DROP TABLE messages" || true
    fi
    sqlite3 "$DB_PATH" "
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            content TEXT,
            user_input TEXT,
            tool_calls TEXT,
            tool_call_id TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
    " || true
}

sql() { echo "$1" | sqlite3 "$DB_PATH" || true; }

add_message() {
    local role="$1" content="$2" input="${3:-}"
    content="${content//\'/''}"
    if [[ -n "$input" ]]; then
        input="${input//\'/''}"
        sql "INSERT INTO messages (role, content, user_input) VALUES ('$role', '$content', '$input')"
    else
        sql "INSERT INTO messages (role, content) VALUES ('$role', '$content')"
    fi
}

save_assistant_tool_call() {
    local content="${1:-}" tool_calls="$2"
    content="${content//\'/''}"
    local tc="${tool_calls//\'/''}"
    if [[ -n "$content" ]]; then
        sql "INSERT INTO messages (role, content, tool_calls) VALUES ('assistant', '$content', '$tc')"
    else
        sql "INSERT INTO messages (role, tool_calls) VALUES ('assistant', '$tc')"
    fi
}

save_tool_result() {
    local tool_call_id="$1" content="$2"
    local cid="${tool_call_id//\'/''}"
    content="${content//\'/''}"
    sql "INSERT INTO messages (role, content, tool_call_id) VALUES ('tool', '$content', '$cid')"
}

run_tool() {
    local name="$1" args="$2"
    local script="$TOOLS_DIR/${name}.sh"
    if [[ ! -f "$script" ]]; then
        echo "Error: unknown tool '$name'"
        return 1
    fi
    bash "$script" "$args"
}

help() {
    echo -e "${C}DeepSeek AI Agent v${AI_AGENT_VERSION}${R}"
    echo ""
    echo -e "${C}Commands:${R}"
    echo "  /read <path>      - Read file and add as context"
    echo "  /grep <pattern>   - Search codebase and add results as context"
    echo "  /exec <command>   - Execute shell command and add output as context"
    echo "  /save <path>      - Save last assistant response to file"
    echo "  /clear            - Clear conversation history"
    echo "  /hist             - Show recent history"
    echo "  /tools            - List available tools"
    echo "  /tools reload     - Reload tools from $TOOLS_DIR"
    echo "  /help             - Show this help"
    echo "  /reload           - Reload the program"
    echo "  /exit             - Exit"
    echo ""
    echo -e "${C}Tip:${R} Use Ctrl+C to interrupt response, Ctrl+D to exit."
}

log() { local c="$1"; shift; echo -e "${c}${*}${R}" >&2; }
info() { log "$B" "$@"; }
ok()   { log "$G" "$@"; }
warn() { log "$Y" "$@"; }


history_messages='[]'
load_history() {
    history_messages=$(sqlite3 "$DB_PATH" "
        SELECT json_group_array(
            json_patch(
                json_object('role', role, 'content', COALESCE(content, '')),
                CASE
                    WHEN tool_calls IS NOT NULL THEN json_object('tool_calls', json(tool_calls))
                    WHEN tool_call_id IS NOT NULL THEN json_object('tool_call_id', tool_call_id)
                    ELSE '{}'
                END
            )
        )
        FROM (SELECT role, content, tool_calls, tool_call_id FROM messages ORDER BY id)
    " 2>/dev/null || echo "[]")
}
prune_history() {
    local count
    count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages" 2>/dev/null || echo 0)
    if [[ $count -gt $MAX_HISTORY ]]; then
        local remove=$((count - MAX_HISTORY))
        sqlite3 "$DB_PATH" "DELETE FROM messages WHERE id IN (SELECT id FROM messages ORDER BY id LIMIT $remove)" || true
    fi
}

tools_json=""
tool_descriptions=""
load_tools() {
    tools_json="[]"
    tool_descriptions=""

    if [[ -f "$TOOLS_CACHE" ]] && [[ -f "$TOOLS_DESC_CACHE" ]] \
        && [[ -z "$(find "$TOOLS_DIR" -maxdepth 1 -name '*.json' -newer "$TOOLS_CACHE" 2>/dev/null)" ]]; then
        tools_json=$(cat "$TOOLS_CACHE")
        tool_descriptions=$(cat "$TOOLS_DESC_CACHE")
        return
    fi

    local def json tool_obj desc_line
    for def in "$TOOLS_DIR"/*.json; do
        [[ -f "$def" ]] || continue
        json=$(cat "$def" 2>/dev/null) || continue

        tool_obj=$(echo "$json" | jq -c '
            {
                "type": "function",
                function: {
                    name: .name,
                    description: .description,
                    parameters: {
                        "type": "object",
                        properties: (.input // {} | with_entries(.value |= {type, description})),
                        required: ([.input // {} | to_entries[] | select(.value.required == true) | .key])
                    }
                }
            }' 2>/dev/null) || continue
        [[ -z "$tool_obj" ]] && continue

        desc_line=$(echo "$json" | jq -r '
            def param_list: .input // {} | to_entries | map("\(.key): \(.value.type)") | join(", ");
            "  - \(.name)(\(param_list)) - \(.description)"
        ' 2>/dev/null)
        [[ -z "$desc_line" ]] && continue

        tools_json=$(echo "$tools_json" | jj push . "$tool_obj" 2>/dev/null) || continue
        tool_descriptions+="$desc_line"$'\n'
    done

    echo "$tools_json" > "$TOOLS_CACHE"
    printf '%s' "$tool_descriptions" > "$TOOLS_DESC_CACHE"
}

handle_tool_call() {
    local tc="$1"
    local name args id
    name=$(jq -r '.function.name // ""' <<< "$tc" 2>/dev/null)
    args=$(jq -r '.function.arguments // ""' <<< "$tc" 2>/dev/null)
    id=$(jq -r '.id // ""' <<< "$tc" 2>/dev/null)

    info "  tool: $name($args) [id=$id]"

    local result
    result=$(run_tool "$name" "$args" 2>&1) || true

    local rlen=${#result}
    if [[ $rlen -gt 10000 ]]; then
        result="${result:0:10000}
... [truncated, $rlen total chars]"
    fi
    save_tool_result "$id" "$result"
}

build_base_messages() {
    local syscontent="$SYSTEM_PROMPT"
    if [[ -n "$tool_descriptions" ]]; then
        syscontent="$syscontent"$'\n\n# available tools\n'"$tool_descriptions"
    fi
    local msgs
    msgs=$(jj push . role system content "$syscontent")
    if [[ "$history_messages" != "[]" && -n "$history_messages" ]]; then
        local hist="${history_messages#[}"
        hist="${hist%]}"
        msgs="${msgs%]},$hist]"
    fi
    echo "$msgs"
}

build_messages() {
    local user_content="$1"
    local msgs
    msgs=$(build_base_messages)
    msgs=$(echo "$msgs" | jj push . role user content "$user_content")
    echo "$msgs"
}

process_input() {
    local input="$1"
    if [[ "$input" == /read\ * ]]; then
        local path="${input#/read }"
        path="${path% }"
        if [[ -f "$path" ]]; then
            local content
            content=$(cat "$path")
            echo -e "OK:Here is the content of \`$path\`:\n\`\`\`\n$content\n\`\`\`"
        else
            echo "ERR:File not found: $path"
        fi
    elif [[ "$input" == /grep\ * ]]; then
        local pattern="${input#/grep }"
        pattern="${pattern% }"
        local search_path="."
        if [[ "$pattern" == *\ * ]]; then
            search_path="${pattern##* }"
            if [[ -d "$search_path" ]]; then
                pattern="${pattern% $search_path}"
            else
                search_path="."
            fi
        fi
        local result
        result=$(grep -rn -- "$pattern" "$search_path" 2>/dev/null | head -100 || true)
        if [[ -n "$result" ]]; then
            echo -e "OK:Search results for \`$pattern\` in \`$search_path\`:\n\`\`\`\n$result\n\`\`\`"
        else
            echo "ERR:No matches found for \`$pattern\`"
        fi
    elif [[ "$input" == /exec\ * ]]; then
        local cmd="${input#/exec }"
        local output
        output=$(eval "$cmd" 2>&1 || true)
        echo -e "OK:Command output for \`$cmd\`:\n\`\`\`\n$output\n\`\`\`"
    else
        echo "OK:$input"
    fi
}

cleanup_orphan_tc() {
    # Fast SQL-level cleanup using json_each
    if sqlite3 "$DB_PATH" "
        DELETE FROM messages WHERE id IN (
            SELECT a.id FROM messages a
            WHERE a.role='assistant' AND a.tool_calls IS NOT NULL
            AND (
                SELECT COUNT(*) FROM json_each(a.tool_calls) AS tc
                WHERE EXISTS (
                    SELECT 1 FROM messages t
                    WHERE t.role='tool' AND t.tool_call_id = json_extract(tc.value, '\$.id')
                )
            ) < (
                SELECT COUNT(*) FROM json_each(a.tool_calls)
            )
        );
        DELETE FROM messages WHERE role='tool' AND tool_call_id NOT IN (
            SELECT DISTINCT json_extract(value, '\$.id')
            FROM messages, json_each(tool_calls)
            WHERE role='assistant' AND tool_calls IS NOT NULL
        );
    " 2>/dev/null; then
        return 0
    fi

    # Fallback bash-level cleanup (for SQLite without json_each)
    local raw i=0
    raw=$(sqlite3 -json "$DB_PATH" "SELECT id, tool_calls FROM messages WHERE role='assistant' AND tool_calls IS NOT NULL" 2>/dev/null || echo "[]")
    [[ "$raw" != "[]" ]] && while true; do
        local aid tc
        aid=$(echo "$raw" | jq -r ".[$i].id // empty" 2>/dev/null) && [[ -z "$aid" ]] && break
        tc=$(echo "$raw" | jq -c ".[$i].tool_calls // empty" 2>/dev/null)
        [[ -z "$tc" ]] && { i=$((i+1)); continue; }
        local j=0 missing=0
        while true; do
            local tcid
            tcid=$(echo "$tc" | jq -r ".[$j].id // empty" 2>/dev/null) && [[ -z "$tcid" ]] && break
            local found
            found=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages WHERE role='tool' AND tool_call_id='${tcid//\'/''}'" 2>/dev/null || echo 0)
            [[ "$found" == "0" ]] && missing=1
            j=$((j+1))
        done
        if (( missing )); then sql "DELETE FROM messages WHERE id=$aid"; fi
        i=$((i+1))
    done

    raw=$(sqlite3 -json "$DB_PATH" "SELECT id, tool_call_id FROM messages WHERE role='tool'" 2>/dev/null || echo "[]")
    if [[ "$raw" != "[]" ]]; then
        i=0
        while true; do
            local tid tcid
            tid=$(echo "$raw" | jq -r ".[$i].id // empty" 2>/dev/null) && [[ -z "$tid" ]] && break
            tcid=$(echo "$raw" | jq -r ".[$i].tool_call_id // empty" 2>/dev/null)
            local found
            found=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages WHERE role='assistant' AND tool_calls IS NOT NULL AND instr(tool_calls, '\"id\":\"$tcid\"') > 0" 2>/dev/null || echo 0)
            if [[ "$found" == "0" ]]; then sql "DELETE FROM messages WHERE id=$tid"; fi
            i=$((i+1))
        done
    fi
}

init_db
cleanup_orphan_tc
prune_history
load_history
load_tools

history -r

echo -e "${B}DeepSeek AI Agent${R} v${AI_AGENT_VERSION}  (${C}${MODEL}${R}) (${BASE_URL})"
echo -e "Type ${C}/help${R} for commands"
echo ""

while true; do
    IFS= read -e -p $'\e[1;32mYou>\e[0m ' -r input || { echo; exit 0; }
    input="${input%"${input##*[![:space:]]}"}"
    [[ -z "$input" ]] && continue
    history -s "$input"

    case "$input" in
        /exit) exit 0 ;;
        /reload) history -w 2>/dev/null || true; exec bash "$0" ;;
        /help) help; continue ;;
        /clear)
            history_messages="[]"
            sqlite3 "$DB_PATH" "DELETE FROM messages" || true
            info "History cleared."
            continue
            ;;
        /hist)
            sqlite3 -header -column "$DB_PATH" "SELECT id, role, substr(content,1,60) as content, user_input, created_at FROM messages ORDER BY id" 2>/dev/null || echo "No messages"
            continue
            ;;
        /tools*)
            if [[ "$input" == "/tools reload" ]]; then
                load_tools
                ok "Tools reloaded"
            elif [[ -n "$tool_descriptions" ]]; then
                echo "Available Tools:"
                echo "$tool_descriptions"
            else
                info "No tools found in $TOOLS_DIR"
            fi
            continue
            ;;
        /save\ *)
            save_path="${input#/save }"
            save_path="${save_path% }"
            if [[ -f "$LAST_RESPONSE_FILE" ]]; then
                cp "$LAST_RESPONSE_FILE" "$save_path"
                ok "Saved to $save_path"
            else
                warn "No response to save"
            fi
            continue
            ;;
    esac

    proc_result=$(process_input "$input")
    if [[ "$proc_result" == ERR:* ]]; then
        warn "${proc_result:4}"
        continue
    fi
    user_content="${proc_result:3}"

    msgs_json=$(build_messages "$user_content")
    echo -en "${B}Agent>${R} "

    _usr_stored=0
    _inner=1
    while (( _inner )); do
        post_data=$(jj set model "$MODEL" messages "$msgs_json")
        if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
            post_data=$(echo "$post_data" | jj set tools "$tools_json")
        fi
        #-H "Authorization: Bearer $API_KEY" 
        response_content=$(curl -sS --connect-timeout 15 --max-time 120 "$API_URL" --json "$post_data") || {
            warn "API request failed (timeout or connection error)"
            _inner=0
            continue 2
        }
        echo "$response_content" >> $LAST_RESPONSE_FILE

        finish_reason=$(jq -r '.choices[0].finish_reason // "stop"' <<< "$response_content" 2>/dev/null)

        if [[ "$finish_reason" == "tool_calls" ]]; then
            if (( ! _usr_stored )); then
                add_message "user" "$user_content" "$input"
                _usr_stored=1
            fi

            asst_msg=$(jq -c '.choices[0].message // empty' <<< "$response_content" 2>/dev/null)
            asst_content=$(jq -r '.content // empty' <<< "$asst_msg" 2>/dev/null)
            tc_array=$(jq -c '.tool_calls // []' <<< "$asst_msg" 2>/dev/null)

            save_assistant_tool_call "$asst_content" "$tc_array"

            for ((_i=0; ; _i++)); do
                tc=$(jq -c ".[$_i] // empty" <<< "$tc_array" 2>/dev/null)
                [[ -z "$tc" || "$tc" == "null" ]] && break
                handle_tool_call "$tc"
            done

            prune_history
            load_history
            msgs_json=$(build_base_messages)
            continue
        fi

        response_text=$(jq -r '.choices[0].message.content // empty' <<< "$response_content" 2>/dev/null)
        if [[ -z "$response_text" ]]; then
            error_msg=$(jq -r '.error.message // empty' <<< "$response_content" 2>/dev/null)
            if [[ -n "$error_msg" ]]; then
                warn "API error: $error_msg"
            else
                warn "API returned empty response"
            fi
            _inner=0
            continue 2
        fi
        think_text=""
        if [[ "$response_text" == *"<think>"* && "$response_text" == *"</think>"* ]]; then
            if [[ "$response_text" =~ \<think\>(.+)\</think\> ]]; then
                think_text="${BASH_REMATCH[1]}"
                response_text="${response_text//"<think>${think_text}</think>"/}"
                response_text="${response_text#"${response_text%%[![:space:]]*}"}"
            fi
        fi
        if [[ -n "$think_text" ]]; then
            echo -e "${D}think: ${think_text}${R}"
            echo
        fi
        echo -e "$response_text"

        if (( ! _usr_stored )); then
            add_message "user" "$user_content" "$input"
        fi
        add_message "assistant" "$response_text"
        _inner=0
    done

    prune_history
    load_history
done
