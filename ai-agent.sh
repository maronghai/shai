#!/usr/bin/env bash
set -euo pipefail

DEEPSEEK_AI_AGENT_VERSION="1.0.0"

API_KEY="$(curl -sS win/ds)"
MODEL="deepseek-v4-flash"
API_URL="https://api.deepseek.com/chat/completions"
# API_URL="http://win:8080/chat/completions"
DATA_DIR=".data"
HISTORY_FILE="$DATA_DIR/history.txt"
MAX_HISTORY=40
TEMP_DIR=".tmp"

R='\033[0m'; B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'

mkdir -p "$DATA_DIR" "$TEMP_DIR"
touch "$HISTORY_FILE"

SYSTEM_PROMPT='You are an AI coding assistant with deep expertise in software development. You help with code generation, debugging, review, architecture, and best practices. Respond in the language the user uses. Keep answers concise and practical. When providing code, include the language identifier and ensure it is correct and complete.'

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
    echo "  /help             - Show this help"
    echo "  /exit             - Exit"
    echo ""
    echo -e "${C}Tip:${R} Use Ctrl+C to interrupt response, Ctrl+D to exit."
}

log() { local c="$1"; shift; echo -e "${c}${*}${R}" >&2; }
info() { log "$B" "$@"; }
ok()   { log "$G" "$@"; }
warn() { log "$Y" "$@"; }

save_history() {
    echo "$history_lines" > "$HISTORY_FILE"
}

history_lines="[]"
load_history() {
    history_lines=$(cat "$HISTORY_FILE")
}

build_messages() {
    local user_msg="$1"
    local msgs
    msgs=$(jj push . role system content "$SYSTEM_PROMPT")
    for line in "${history_lines[@]}"; do
        local role content
        role=$(echo "$line" | jj -f - get role --raw 2>/dev/null || true)
        content=$(echo "$line" | jj -f - get content --raw 2>/dev/null || true)
        [[ -z "$role" || -z "$content" ]] && continue
        msgs=$(echo "$msgs" | jj push '' role "$role" content "$content")
    done
    msgs=$(echo "$msgs" | jj push '' role user content "$user_msg")
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

load_history

echo -e "${B}DeepSeek AI Agent${R} v${DEEPSEEK_AI_AGENT_VERSION}  (${C}${MODEL}${R})"
echo -e "Type ${C}/help${R} for commands"
echo ""

while true; do
    echo -en "${G}You>${R} "
    IFS= read -r input || { echo; exit 0; }
    input="${input%"${input##*[![:space:]]}"}"
    [[ -z "$input" ]] && continue

    case "$input" in
        /exit) exit 0 ;;
        /help) help; continue ;;
        /clear)
            history_lines="[]"
            save_history
            info "History cleared."
            continue
            ;;
        /hist)
            echo $history_lines
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

    post_data="$(jj set model $MODEL thinking.type disabled messages "$msgs_json")"
    response_content=$(curl -sS "$API_URL" -H "Authorization: Bearer $API_KEY" --json "$post_data")
    echo $(jj get choices.0.message.content <<< $response_content --raw)

    user_entry=$(jj set role user content "$input")
    assistant_entry=$(jj get choices.0.message <<< $response_content --raw)

    
    history_lines=$(jj push $user_entry $assistant_entry <<< $history_lines)

    save_history

    if [[ -n "$response_content" ]]; then
        echo "$response_content" >> "$TEMP_DIR/last-response.txt"
    fi
done
