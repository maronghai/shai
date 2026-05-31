#!/usr/bin/env bash
set -euo pipefail

DEEPSEEK_AI_AGENT_VERSION="1.0.0"

API_KEY="${API_KEY:-$(curl -sS win/ds 2>/dev/null || echo "")}"
MODEL="${MODEL:-deepseek-v4-flash}"
API_URL="https://api.deepseek.com/chat/completions"
API_URL="${API_URL:-http://win:8080/chat/completions}"
DATA_DIR=".data"
DB_PATH="$DATA_DIR/chat.db"
TOOLS_FILE="$DATA_DIR/tools.json"
MAX_HISTORY=40
TEMP_DIR=".tmp"
HISTFILE="$DATA_DIR/.input_history"
HISTFILESIZE=1000
HISTSIZE=1000

R='\033[0m'; B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'

mkdir -p "$DATA_DIR" "$TEMP_DIR"

trap 'history -w 2>/dev/null || true' EXIT INT

command -v sqlite3 >/dev/null 2>&1 || { echo "Error: sqlite3 is required" >&2; exit 1; }

SYSTEM_PROMPT="$(cat SYSTEM_PROMPT.md)"

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

help() {
    echo -e "${C}DeepSeek AI Agent v${DEEPSEEK_AI_AGENT_VERSION}${R}"
    echo ""
    echo -e "${C}Commands:${R}"
    echo "  /read <path>      - Read file and add as context"
    echo "  /grep <pattern>   - Search codebase and add results as context"
    echo "  /exec <command>   - Execute shell command and add output as context"
    echo "  /save <path>      - Save last assistant response to file"
    echo "  /clear            - Clear conversation history"
    echo "  /hist             - Show recent history"
    echo "  /tools            - List available tools"
    echo "  /tools reload     - Reload tools from config"
    echo "  /help             - Show this help"
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
            json_object(
                'role', role,
                'content', content,
                'tool_calls', CASE WHEN tool_calls IS NOT NULL THEN json(tool_calls) ELSE NULL END,
                'tool_call_id', tool_call_id
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
load_tools() {
    if [[ -f "$TOOLS_FILE" ]]; then
        tools_json=$(cat "$TOOLS_FILE" 2>/dev/null || echo "")
        if echo "${tools_json:-}" | jj type . 2>/dev/null | grep -qv '^array$'; then
            tools_json=""
        fi
    fi
}

handle_tool_call() {
    local tc="$1"
    local name args id
    name=$(jj get function.name --raw <<< "$tc" 2>/dev/null || echo "")
    args=$(jj get function.arguments --raw <<< "$tc" 2>/dev/null || echo "")
    id=$(jj get id --raw <<< "$tc" 2>/dev/null || echo "")

    info "  tool: $name($args) [id=$id]"

    local result=""
    case "$name" in
        read_file)
            local path=$(echo "$args" | jj get path --raw 2>/dev/null || echo "")
            if [[ -f "$path" ]]; then
                result=$(cat "$path")
            else
                result="Error: File not found: $path"
            fi
            ;;
        grep_search)
            local pattern=$(echo "$args" | jj get pattern --raw 2>/dev/null || echo "")
            local spath=$(echo "$args" | jj get path --raw 2>/dev/null || echo ".")
            result=$(grep -rn -- "$pattern" "$spath" 2>/dev/null | head -100 || echo "No matches")
            ;;
        exec_command)
            local cmd=$(echo "$args" | jj get command --raw 2>/dev/null || echo "")
            result=$(eval "$cmd" 2>&1 || echo "Command failed")
            ;;
        *)
            result="Error: unknown tool '$name'"
            ;;
    esac

    local rlen=${#result}
    if [[ $rlen -gt 10000 ]]; then
        result="${result:0:10000}
... [truncated, $rlen total chars]"
    fi
    save_tool_result "$id" "$result"
}

build_base_messages() {
    local msgs
    msgs=$(echo '[]' | jj push . role system content "$SYSTEM_PROMPT")
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
    local raw
    raw=$(sqlite3 -json "$DB_PATH" "SELECT id, tool_calls FROM messages WHERE role='assistant' AND tool_calls IS NOT NULL" 2>/dev/null || echo "[]")
    [[ "$raw" == "[]" ]] && return
    local i=0
    while true; do
        local aid tc
        aid=$(echo "$raw" | jj get ".${i}.id" --raw 2>/dev/null || echo "")
        [[ -z "$aid" ]] && break
        tc=$(echo "$raw" | jj get ".${i}.tool_calls" 2>/dev/null || echo "")
        local j=0 missing=0
        while true; do
            local tcid
            tcid=$(echo "$tc" | jj get ".${j}.id" --raw 2>/dev/null || echo "")
            [[ -z "$tcid" ]] && break
            local found
            found=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages WHERE role='tool' AND tool_call_id='${tcid//\'/''}'" 2>/dev/null || echo 0)
            [[ "$found" == "0" ]] && missing=1
            j=$((j+1))
        done
        if (( missing )); then
            sql "DELETE FROM messages WHERE id=$aid"
        fi
        i=$((i+1))
    done
}

init_db
cleanup_orphan_tc
load_history
load_tools

history -r

echo -e "${B}DeepSeek AI Agent${R} v${DEEPSEEK_AI_AGENT_VERSION}  (${C}${MODEL}${R})"
echo -e "Type ${C}/help${R} for commands"
echo ""

while true; do
    IFS= read -e -p $'\e[1;32mYou>\e[0m ' -r input || { echo; exit 0; }
    input="${input%"${input##*[![:space:]]}"}"
    [[ -z "$input" ]] && continue
    history -s "$input"

    case "$input" in
        /exit) exit 0 ;;
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
            elif [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
                echo "$tools_json"
            else
                info "No tools loaded (edit $TOOLS_FILE)"
            fi
            continue
            ;;
        /save\ *)
            save_path="${input#/save }"
            save_path="${save_path% }"
            if [[ -f "$TEMP_DIR/last-response.txt" ]]; then
                cp "$TEMP_DIR/last-response.txt" "$save_path"
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

        response_content=$(curl -sS --connect-timeout 15 --max-time 120 "$API_URL" -H "Authorization: Bearer $API_KEY" --json "$post_data") || {
            warn "API request failed (timeout or connection error)"
            _inner=0
            continue 2
        }

        finish_reason=$(jj get choices.0.finish_reason --raw <<< "$response_content" 2>/dev/null || echo "stop")

        if [[ "$finish_reason" == "tool_calls" ]]; then
            if (( ! _usr_stored )); then
                add_message "user" "$user_content" "$input"
                _usr_stored=1
            fi

            asst_msg=$(jj get choices.0.message --raw <<< "$response_content" 2>/dev/null || echo "")
            asst_content=$(jj get content --raw <<< "$asst_msg" 2>/dev/null || echo "")
            tc_array=$(jj get tool_calls <<< "$asst_msg" 2>/dev/null || echo "[]")
            if [[ "$asst_content" == "null" ]]; then asst_content=""; fi

            save_assistant_tool_call "$asst_content" "$tc_array"

            for ((_i=0; ; _i++)); do
                tc=$(echo "$tc_array" | jj get ".$_i" 2>/dev/null || echo "")
                [[ -z "$tc" ]] && break
                handle_tool_call "$tc"
            done

            prune_history
            load_history
            msgs_json=$(build_base_messages)
            continue
        fi

        response_text=$(jj get choices.0.message.content --raw <<< "$response_content" 2>/dev/null) || true
        if [[ -z "$response_text" ]]; then
            error_msg=$(jj get error.message --raw <<< "$response_content" 2>/dev/null) || true
            if [[ -n "$error_msg" ]]; then
                warn "API error: $error_msg"
            else
                warn "API returned empty response"
            fi
            echo "$response_content" >> "$TEMP_DIR/last-response.txt"
            _inner=0
            continue 2
        fi
        echo "$response_text"

        if (( ! _usr_stored )); then
            add_message "user" "$user_content" "$input"
        fi
        add_message "assistant" "$response_text"
        _inner=0
    done

    prune_history
    load_history

    if [[ -n "$response_content" ]]; then
        echo "$response_content" >> "$TEMP_DIR/last-response.txt"
    fi
done
