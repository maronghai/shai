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

R='\033[0m'; B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'; D='\033[2m'; DM='\033[90m'

mkdir -p "$DATA_DIR" "$TEMP_DIR"

trap 'history -w 2>/dev/null || true' EXIT
trap 'echo; history -w 2>/dev/null || true; exit 0' INT

command -v sqlite3 >/dev/null 2>&1 || { echo "Error: sqlite3 is required" >&2; exit 1; }

SYSTEM_PROMPT="$(cat ${WORK_DIR}/SYSTEM_PROMPT.md)"

init_db() {
    if ! sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$DB_PATH" \
        "SELECT 1 FROM pragma_table_info('messages') WHERE name='thinking'" 2>/dev/null | grep -q 1; then
        sqlite3 "$DB_PATH" "DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS tool_calls;" || true
    fi
    sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$DB_PATH" <<'SQL' || true
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL CHECK (role IN ('system','user','assistant')),
            content TEXT,
            raw_input TEXT,
            thinking TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS tool_calls (
            id TEXT PRIMARY KEY,
            message_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            arguments TEXT NOT NULL,
            result TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_tool_calls_message ON tool_calls(message_id);
SQL
}

sql() { sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$DB_PATH" <<< "$1" || true; }
db_quote() {
    local q s
    q="''"
    s="${1//\'/$q}"
    printf "'%s'" "$s"
}
db_exec_returning() {
    sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$DB_PATH" \
        "INSERT INTO messages (role, content) VALUES ('assistant', $(db_quote "$1")); SELECT last_insert_rowid();" 2>/dev/null | tail -1
}

add_message() {
    local role="$1" content="$2" raw="${3:-}" thinking="${4:-}"
    local columns="(role, content" values="($(db_quote "$role"), $(db_quote "$content")"
    if [[ -n "$raw" ]]; then
        columns+=", raw_input"
        values+=", $(db_quote "$raw")"
    fi
    if [[ -n "$thinking" ]]; then
        columns+=", thinking"
        values+=", $(db_quote "$thinking")"
    fi
    columns+=")"
    values+=")"
    sql "INSERT INTO messages $columns VALUES $values"
}

save_assistant_tool_call() {
    local content="${1:-}" tc_array="$2" thinking="${3:-}"
    local mid
    mid=$(db_exec_returning "$content")
    if [[ -z "$mid" || "$mid" == "0" ]]; then
        warn "save_assistant_tool_call: failed to insert assistant message"
        return 1
    fi
    if [[ -n "$thinking" ]]; then
        sql "UPDATE messages SET thinking=$(db_quote "$thinking") WHERE id=$mid"
    fi

    local i=0 tc tcid name args
    while true; do
        tc=$(jq -c --argjson i "$i" '.[$i] // empty' <<< "$tc_array" 2>/dev/null) || break
        [[ -z "$tc" || "$tc" == "null" ]] && break
        tcid=$(jq -r '.id // ""' <<< "$tc")
        name=$(jq -r '.function.name // ""' <<< "$tc")
        args=$(jq -r '.function.arguments // "{}"' <<< "$tc")
        sql "INSERT INTO tool_calls (id, message_id, name, arguments) VALUES ($(db_quote "$tcid"), $mid, $(db_quote "$name"), $(db_quote "$args"))"
        i=$((i+1))
    done
}

save_tool_result() {
    local call_id="$1" result="$2"
    sql "UPDATE tool_calls SET result=$(db_quote "$result") WHERE id=$(db_quote "$call_id")"
}

run_tool() {
    local name="$1" args="$2"
    local tool_def interpreter script_path
    tool_def=$(echo "$tools_json" | jq -c --arg n "$name" '.[] | select(.function.name == $n)' 2>/dev/null)
    if [[ -z "$tool_def" || "$tool_def" == "null" ]]; then
        echo "Error: unknown tool '$name'"
        return 1
    fi
    interpreter=$(echo "$tool_def" | jq -r '.run.interpreter // "bash"' 2>/dev/null)
    script_path=$(echo "$tool_def" | jq -r '.run.script // ""' 2>/dev/null)
    if [[ -z "$script_path" ]]; then
        echo "Error: tool '$name' has no run.script"
        return 1
    fi
    "$interpreter" "$TOOLS_DIR/$script_path" "$args"
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
        SELECT json_group_array(json(payload)) FROM (
            WITH stream AS (
                SELECT m.id AS msg_id, 0 AS ord,
                       CASE
                           WHEN m.role IN ('system','user') THEN
                               json_object('role', m.role, 'content', COALESCE(m.content, ''))
                           WHEN m.role = 'assistant' AND EXISTS (SELECT 1 FROM tool_calls WHERE message_id = m.id) THEN
                               json_object(
                                   'role', 'assistant',
                                   'content', COALESCE(m.content, ''),
                                   'tool_calls', (
                                       SELECT json_group_array(json_object(
                                           'id', tc.id,
                                           'type', 'function',
                                           'function', json_object('name', tc.name, 'arguments', tc.arguments)
                                       ))
                                       FROM tool_calls tc WHERE tc.message_id = m.id ORDER BY tc.rowid
                                   )
                               )
                           WHEN m.role = 'assistant' THEN
                               json_object('role', 'assistant', 'content', COALESCE(m.content, ''))
                       END AS payload
                FROM messages m
                UNION ALL
                SELECT tc.message_id, tc.rowid,
                       json_object('role', 'tool', 'content', COALESCE(tc.result, ''), 'tool_call_id', tc.id)
                FROM tool_calls tc
                INNER JOIN messages m2 ON m2.id = tc.message_id
            )
            SELECT payload FROM stream ORDER BY msg_id, ord
        )
    " 2>/dev/null || echo "[]")
}
prune_history() {
    local count
    count=$(sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$DB_PATH" "SELECT COUNT(*) FROM messages" 2>/dev/null || echo 0)
    if [[ $count -gt $MAX_HISTORY ]]; then
        local remove=$((count - MAX_HISTORY))
        sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$DB_PATH" \
            "DELETE FROM messages WHERE id IN (SELECT id FROM messages ORDER BY id LIMIT $remove)" || true
    fi
}

tools_json=""
tools_wire_json="[]"
tool_descriptions=""
load_tools() {
    tools_json="[]"
    tools_wire_json="[]"
    tool_descriptions=""

    if [[ -f "$TOOLS_CACHE" ]] && [[ -f "$TOOLS_DESC_CACHE" ]] \
        && [[ -z "$(find "$TOOLS_DIR" -maxdepth 1 -name '*.json' -newer "$TOOLS_CACHE" 2>/dev/null)" ]]; then
        tools_json=$(cat "$TOOLS_CACHE")
        tool_descriptions=$(cat "$TOOLS_DESC_CACHE")
        tools_wire_json=$(echo "$tools_json" | jq -c 'map(del(.run))' 2>/dev/null)
        return
    fi

    local def tool_obj name interpreter script_path desc_line
    for def in "$TOOLS_DIR"/*.json; do
        [[ -f "$def" ]] || continue
        tool_obj=$(cat "$def" 2>/dev/null) || continue

        name=$(echo "$tool_obj" | jq -r '.function.name // ""' 2>/dev/null)
        [[ "$name" == "" ]] && continue
        [[ "$(echo "$tool_obj" | jq -r '.type // ""' 2>/dev/null)" != "function" ]] && continue

        interpreter=$(echo "$tool_obj" | jq -r '.run.interpreter // "bash"' 2>/dev/null)
        script_path=$(echo "$tool_obj" | jq -r '.run.script // ""' 2>/dev/null)
        if [[ -z "$script_path" || ! -f "$TOOLS_DIR/$script_path" ]]; then
            warn "Skipping tool '$name': run.script missing or not found: $script_path"
            continue
        fi

        desc_line=$(echo "$tool_obj" | jq -r '
            def params: .function.parameters.properties // {} | to_entries | map("\(.key): \(.value.type)") | join(", ");
            "  - \(.function.name)(\(params)) - \(.function.description)"
        ' 2>/dev/null)
        [[ -z "$desc_line" || "$desc_line" == "null" ]] && continue

        tools_json=$(echo "$tools_json" | jj push . "$tool_obj" 2>/dev/null) || continue
        tool_descriptions+="$desc_line"$'\n'
    done

    tools_wire_json=$(echo "$tools_json" | jq -c 'map(del(.run))' 2>/dev/null)

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

init_db
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
            sql "DELETE FROM messages"
            info "History cleared."
            continue
            ;;
        /hist)
            echo "== messages =="
            sqlite3 -header -column "$DB_PATH" "SELECT id, role, substr(COALESCE(content,'<null>'),1,60) as content, COALESCE(raw_input,'') as raw_input, CASE WHEN thinking IS NULL THEN '' ELSE length(thinking) || ' chars' END as thinking FROM messages ORDER BY id" 2>/dev/null || echo "No messages"
            echo
            echo "== tool_calls =="
            sqlite3 -header -column "$DB_PATH" "SELECT id, message_id, name, substr(COALESCE(arguments,'{}'),1,40) as arguments, length(COALESCE(result,'')) as result_len FROM tool_calls ORDER BY message_id, rowid" 2>/dev/null || echo "No tool calls"
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
        if [[ -n "$tools_wire_json" && "$tools_wire_json" != "[]" ]]; then
            post_data=$(echo "$post_data" | jj set tools "$tools_wire_json")
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

            asst_thinking=""
            if [[ "$asst_content" == *"<think>"* && "$asst_content" == *"</think>"* ]]; then
                if [[ "$asst_content" =~ \<think\>(.+)\</think\> ]]; then
                    asst_thinking="${BASH_REMATCH[1]}"
                    asst_content="${asst_content//"<think>${asst_thinking}</think>"/}"
                    asst_content="${asst_content#"${asst_content%%[![:space:]]*}"}"
                fi
            fi
            echo -e "${C}think:${R} ${DM}${asst_thinking:-(no reasoning)}${R}"
            echo

            save_assistant_tool_call "$asst_content" "$tc_array" "$asst_thinking"

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
        echo -e "${C}think:${R} ${DM}${think_text:-(no reasoning)}${R}"
        echo
        echo -e "$response_text"

        if (( ! _usr_stored )); then
            add_message "user" "$user_content" "$input"
        fi
        add_message "assistant" "$response_text" "" "$think_text"
        _inner=0
    done

    prune_history
    load_history
done
