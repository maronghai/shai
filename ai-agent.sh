#!/usr/bin/env bash
# ai-agent.sh — AI Agent terminal client with multi-agent + /team dispatch.
# Sourced libs:
#   lib/db.sh    — DB primitives, history, /hist dumpers
#   lib/team.sh  — /team workflow dispatcher
#   lib/agent.sh — persona switching, listing, REPL prompt
#   lib/cmd.sh   — slash-command "did you mean" suggestions
#   lib/complete.sh — TAB completion in the REPL
set -euo pipefail
WORK_DIR="$(cd "$(dirname "$0")" && pwd)"

AI_AGENT_VERSION="0.0.14"

$(curl -sS win/v1)
API_URL="${BASE_URL}/v1/chat/completions"

DATA_DIR="${WORK_DIR}/.data"
TEMP_DIR="${WORK_DIR}/.tmp"
TOOLS_DIR="${WORK_DIR}/tools"
LAST_RESPONSE_FILE="${TEMP_DIR}/last-response.txt"
HISTFILE="$DATA_DIR/.input_history"
HISTFILESIZE=1000
HISTSIZE=1000
AGENTS_DIR="${WORK_DIR}/agents"
CURRENT_AGENT=""
CURRENT_AGENT_FILE="$DATA_DIR/.current_agent"
AI_AGENT_DB="${AI_AGENT_DB:-$DATA_DIR/ai-agent.db}"
TEAM_SCHEMA="$WORK_DIR/team/schema.sql"
MAX_HISTORY=40

R='\033[0m'; B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'; D='\033[2m'; DM='\033[90m'

mkdir -p "$DATA_DIR" "$TEMP_DIR"

# Source the library modules
. "$WORK_DIR/lib/db.sh"
. "$WORK_DIR/lib/team.sh"
. "$WORK_DIR/lib/agent.sh"
. "$WORK_DIR/lib/cmd.sh"
. "$WORK_DIR/lib/complete.sh"

# Restore last-used agent (if any)
if [[ -f "$CURRENT_AGENT_FILE" ]]; then
    _candidate=$(cat "$CURRENT_AGENT_FILE" 2>/dev/null) || _candidate=""
    if [[ "$_candidate" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ -f "$AGENTS_DIR/$_candidate/system.md" ]]; then
        CURRENT_AGENT="$_candidate"
    else
        rm -f "$CURRENT_AGENT_FILE" 2>/dev/null || true
    fi
fi

AI_AGENT_DB="${AI_AGENT_DB:-$DATA_DIR/ai-agent.db}"
TOOLS_CACHE="$DATA_DIR/tools_cache${CURRENT_AGENT:+_$CURRENT_AGENT}.json"
TOOLS_DESC_CACHE="$DATA_DIR/tools_desc${CURRENT_AGENT:+_$CURRENT_AGENT}.txt"

trap 'history -w 2>/dev/null || true' EXIT

# Safer Ctrl+C: writing a timestamp is the only thing the trap does.
# The main REPL loop reads the timestamp and decides whether to:
#   (a) show a "use /exit to quit" hint and clear the line (first press)
#   (b) actually exit (second press within INT_WINDOW seconds)
# This avoids one-shot exit on accidental Ctrl+C at the prompt.
_INT_TS_FILE="$TEMP_DIR/.int_ts"
_INT_WINDOW=2
trap 'printf "%s" "$(date +%s)" > "$_INT_TS_FILE" 2>/dev/null' INT

SYSTEM_PROMPT="$(load_system_prompt)"

# ----- logging helpers (used by lib/*.sh) -----
log() { local c="$1"; shift; echo -e "${c}${*}${R}" >&2; }
info() { log "$B" "$@"; }
ok()   { log "$G" "$@"; }
warn() { log "$Y" "$@"; }

# ----- tool loading + dispatch -----
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
    AGENT_NAME="$CURRENT_AGENT" AI_AGENT_DB="$AI_AGENT_DB" \
    WORK_DIR="$WORK_DIR" AGENTS_DIR="$AGENTS_DIR" \
    DELEGATION_DEPTH="${DELEGATION_DEPTH:-0}" \
        "$interpreter" "$TOOLS_DIR/$script_path" "$args"
}

help() {
    echo -e "${C}AI Agent v${AI_AGENT_VERSION}${R}"
    echo ""
    echo -e "${C}Commands:${R}"
    echo "  /read <path>      - Read file and add as context"
    echo "  /grep <pattern>   - Search codebase and add results as context"
    echo "  /exec <command>   - Execute shell command and add output as context"
    echo "  /save <path>      - Save last assistant response to file"
    echo "  /clear            - Clear conversation history"
    echo "  /hist             - Show recent history (summary view)
  /hist full        - Show every message + tool_call in full
  /hist full <id>   - Show one message in full style + its tool calls
  /hist <id>        - Show one message (full content) + its tool calls"
    echo "  /tools            - List available tools"
    echo "  /tools reload     - Reload tools from $TOOLS_DIR"
    echo "  /agent            - Show current agent (name, description, tags, db, msgs, tools)"
    echo "  /agent <name|id>  - Switch to named agent (or 1-based /agents list number)"
    echo "  /agent reload     - Reload current agent's prompt + tools"
    echo "  /agents           - List all available agents (numbered; with description and tags)
  /agents @tag      - List agents whose frontmatter tags include @tag"
    echo "  /board                        - List all blackboard topics (with counts)"
    echo "  /board write <topic> <msg>    - Write a new entry to a topic"
    echo "  /board reply <id> <msg>       - Write a reply to entry <id> (same topic)"
    echo "  /board clear <topic> [-y]     - Soft: rename '[cleared] <topic>' | -y: DELETE rows"
    echo "  /board topics [prefix]        - List distinct topics (optional prefix filter)"
    echo "  /board grep <pattern>         - Search payloads across all topics (SQL LIKE)"
    echo "  /board stat                   - Overall stats + by-agent breakdown"
    echo "  /board <topic> [opts] [<id>]  - List entries; --since <id> | -n <N> | <id> for full payload"
    echo "  /tasks            - List all tasks (compact)"
    echo "  /tasks <status>   - List tasks filtered by status (pending|done|...)"
    echo "  /tasks ready      - List pending tasks whose depends_on are all done"
    echo "  /task <id>        - Show one task with full event log"
    echo "  /task clear       - Soft cancel: flip non-done tasks to 'cancelled' (done kept, goal kept, audit preserved)"
    echo "  /task clear -y    - HARD full-wipe: remove ALL task rows + ALL events (incl. done, can't undo)"
    echo "  /team             - Show team status (current goal + tasks + ready)"
    echo "  /team start <goal>- Start a team session (PM breaks the goal into tasks)"
    echo "  /team next        - Dispatch the next ready task to its agent"
    echo "  /team stop        - Clear the current goal (keep tasks)"
    echo "  /team clear [-y]  - Soft cancel: flip non-done tasks to 'cancelled' + clear goal"
    echo "  /help             - Show this help"
    echo "  /reload           - Reload the program"
    echo "  /exit             - Exit"
    echo ""
    echo -e "${C}Tip:${R} Ctrl+C clears the current line (press twice in 2s to quit, or use /exit / Ctrl+D)."
}

tools_json=""
tools_wire_json="[]"
tool_descriptions=""
_loaded_tool_obj=""
load_tools() {
    tools_json="[]"
    tools_wire_json="[]"
    tool_descriptions=""

    local agent_tools_dir=""
    if [[ -n "$CURRENT_AGENT" && -d "$AGENTS_DIR/$CURRENT_AGENT/tools" ]]; then
        agent_tools_dir="$AGENTS_DIR/$CURRENT_AGENT/tools"
    fi

    local newer_base="" newer_agent=""
    newer_base=$(find "$TOOLS_DIR" -maxdepth 1 -name '*.json' -newer "$TOOLS_CACHE" 2>/dev/null || echo "")
    if [[ -n "$agent_tools_dir" ]]; then
        newer_agent=$(find "$agent_tools_dir" -maxdepth 1 -name '*.json' -newer "$TOOLS_CACHE" 2>/dev/null || echo "")
    fi
    if [[ -f "$TOOLS_CACHE" ]] && [[ -f "$TOOLS_DESC_CACHE" ]] \
        && [[ -z "$newer_base" ]] && [[ -z "$newer_agent" ]]; then
        tools_json=$(cat "$TOOLS_CACHE")
        tool_descriptions=$(cat "$TOOLS_DESC_CACHE")
        tools_wire_json=$(echo "$tools_json" | jq -c 'map(del(.run))' 2>/dev/null)
        return
    fi

    _load_one_tool() {
        local def="$1" base_dir="$2"
        [[ -f "$def" ]] || return 1
        local tool_obj name script_path
        tool_obj=$(cat "$def" 2>/dev/null) || return 1
        name=$(echo "$tool_obj" | jq -r '.function.name // ""' 2>/dev/null)
        [[ -z "$name" ]] && return 1
        [[ "$(echo "$tool_obj" | jq -r '.type // ""' 2>/dev/null)" != "function" ]] && return 1
        script_path=$(echo "$tool_obj" | jq -r '.run.script // ""' 2>/dev/null)
        if [[ -z "$script_path" || ! -f "$base_dir/$script_path" ]]; then
            warn "Skipping tool '$name': run.script missing or not found: $script_path"
            return 1
        fi
        _loaded_tool_obj="$tool_obj"
        return 0
    }

    local def
    for def in "$TOOLS_DIR"/*.json; do
        [[ -f "$def" ]] || continue
        if _load_one_tool "$def" "$TOOLS_DIR"; then
            tools_json=$(echo "$tools_json" | jj push . "$_loaded_tool_obj" 2>/dev/null) || true
        fi
    done

    if [[ -n "$agent_tools_dir" ]]; then
        for def in "$agent_tools_dir"/*.json; do
            [[ -f "$def" ]] || continue
            if _load_one_tool "$def" "$agent_tools_dir"; then
                tools_json=$(echo "$tools_json" | jj push . "$_loaded_tool_obj" 2>/dev/null) || true
            fi
        done
        tools_json=$(echo "$tools_json" | jq -c 'group_by(.function.name) | map(last)' 2>/dev/null) || true
    fi

    tool_descriptions=$(echo "$tools_json" | jq -r '
        def params: .function.parameters.properties // {} | to_entries | map("\(.key): \(.value.type)") | join(", ");
        .[] | "  - \(.function.name)(\(params)) - \(.function.description)"
    ' 2>/dev/null)

    tools_wire_json=$(echo "$tools_json" | jq -c 'map(del(.run))' 2>/dev/null)

    echo "$tools_json" > "$TOOLS_CACHE"
    printf '%s' "$tool_descriptions" > "$TOOLS_DESC_CACHE"
}

_print_agent_line() {
    local idx="$1" name="$2" desc="$3" tags="$4" marker="$5"
    if [[ -n "$tags" ]]; then
        printf '%s %2d. %-18s %-44s [%s]\n' "$marker" "$idx" "$name" "$desc" "$tags"
    else
        printf '%s %2d. %-18s %s\n' "$marker" "$idx" "$name" "$desc"
    fi
}

# ----- ReAct loop helpers -----
history_messages='[]'

run_non_interactive() {
    local task="${TASK:-}"
    local topic="${TOPIC:-}"
    local parent_id="${PARENT_ID:-}"
    local depth="${DELEGATION_DEPTH:-0}"
    local max_iters="${MAX_NON_INTERACTIVE_ITERS:-5}"

    if [[ -n "${AGENT_NAME:-}" ]]; then
        if ! switch_agent "${AGENT_NAME}"; then
            echo "ERR: cannot switch to agent '${AGENT_NAME}'" >&2
            return 1
        fi
    fi

    if (( depth >= 2 )); then
        SYSTEM_PROMPT="$SYSTEM_PROMPT

# restriction
You are a delegated sub-agent at depth $depth. Do NOT call any further delegation, recursive agent tools, or any tool that spawns new agents. Just answer the task directly with the tools you have."
    fi

    # Defense in depth: sub-agents (any depth) never get `exec_command` --
    # they should use read_file / grep_search instead of arbitrary shell.
    #
    # `agent_delegate` is gated by DELEGATION_DEPTH: depth 0 and 1 keep it
    # (so a top-level orchestrator or a "team lead" sub-agent can fan out),
    # depth >= 2 strips it (so a leaf worker cannot recursively spawn more).
    # This matches the depth cap enforced in tools/agent_delegate.sh.
    local jq_filter='.function.name != "exec_command"'
    if (( depth >= 2 )); then jq_filter='.function.name != "exec_command" and .function.name != "agent_delegate"'; fi
    tools_json=$(echo "$tools_json" | jq -c "map(select(${jq_filter}))" 2>/dev/null) || true
    tools_wire_json=$(echo "$tools_wire_json" | jq -c "map(select(${jq_filter}))" 2>/dev/null) || true
    local strip_desc='(^| )exec_command\('
    if (( depth >= 2 )); then strip_desc='(^| )(exec_command|agent_delegate)\('; fi
    tool_descriptions=$(echo "$tool_descriptions" | grep -v -E "$strip_desc" 2>/dev/null) || true

    local msgs_json
    msgs_json=$(build_base_messages)
    msgs_json=$(echo "$msgs_json" | jj push . role user content "$task")

    local iter=0
    while (( iter < max_iters )); do
        iter=$((iter + 1))
        local post_data response_content finish_reason
        post_data=$(jj set model "$MODEL" messages "$msgs_json")
        if [[ -n "$tools_wire_json" && "$tools_wire_json" != "[]" ]]; then
            post_data=$(echo "$post_data" | jj set tools "$tools_wire_json")
        fi
        response_content=$(curl -sS --connect-timeout 15 --max-time 120 "$API_URL" --json "$post_data" 2>/dev/null) || {
            echo "ERR: api call failed" >&2
            return 1
        }
        finish_reason=$(jq -r '.choices[0].finish_reason // "stop"' <<< "$response_content" 2>/dev/null)
        if [[ "$finish_reason" == "tool_calls" ]]; then
            local asst_content tc_array
            asst_content=$(jq -r '.choices[0].message.content // ""' <<< "$response_content" 2>/dev/null)
            tc_array=$(jq -c '.choices[0].message.tool_calls // []' <<< "$response_content" 2>/dev/null)
            save_assistant_tool_call "$asst_content" "$tc_array" ""
            for ((_i=0; ; _i++)); do
                tc=$(jq -c ".[$_i] // empty" <<< "$tc_array" 2>/dev/null) || break
                [[ -z "$tc" || "$tc" == "null" ]] && break
                handle_tool_call "$tc"
            done
            prune_history
            load_history
            msgs_json=$(build_base_messages)
            msgs_json=$(echo "$msgs_json" | jj push . role user content "$task")
            continue
        fi
        local response_text
        response_text=$(jq -r '.choices[0].message.content // ""' <<< "$response_content" 2>/dev/null)
        if [[ -z "$response_text" ]]; then
            local err_msg
            err_msg=$(jq -r '.error.message // "empty response"' <<< "$response_content" 2>/dev/null)
            echo "ERR: ${err_msg:-empty response}" >&2
            return 1
        fi
        add_message "assistant" "$response_text"
        if [[ -n "$topic" ]]; then
            local payload="${response_text:0:8000}"
            local pllen=${#response_text}
            if (( pllen > 8000 )); then
                payload="${payload}
... [truncated, $pllen total chars]"
            fi
            local r_field="" r_val=""
            if [[ -n "$parent_id" ]]; then
                r_field=", reply_to"
                r_val=", $parent_id"
            fi
            bb_sql "INSERT INTO board (agent, topic, payload${r_field}) VALUES ($(bb_quote "$CURRENT_AGENT"), $(bb_quote "$topic"), $(bb_quote "$payload")${r_val});"
        fi
        echo "$response_text"
        return 0
    done
    echo "ERR: max iterations ($max_iters) reached" >&2
    return 1
}

handle_tool_call() {
    local tc="$1"
    local name args id
    name=$(jq -r '.function.name // ""' <<< "$tc" 2>/dev/null)
    args=$(jq -r '.function.arguments // ""' <<< "$tc" 2>/dev/null)
    id=$(jq -r '.id // ""' <<< "$tc" 2>/dev/null)

    if ! jq -e . >/dev/null 2>&1 <<< "$args"; then
        warn "tool call '$name' (id=$id) has invalid JSON arguments: $args"
        args='{}'
        run_tool "$name" "$args" >/dev/null 2>&1 || true
        save_tool_result "$id" '{"success":false,"error":"model emitted invalid JSON for arguments; rerun with valid JSON"}'
        return
    fi

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

# ----- boot: init DBs, restore history, load tools -----
init_db
init_blackboard
init_team_db
prune_history
load_history
load_tools

# ----- non-interactive entry (used by agent_delegate) -----
if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
    run_non_interactive
    exit $?
fi

# ----- REPL -----
history -r

echo -e "${B}AI Agent${R} v${AI_AGENT_VERSION}  (${C}${MODEL}${R}) (${BASE_URL})"
echo -e "Type ${C}/help${R} for commands"
echo -e "Prompt shows current agent (e.g. ${G}You [default]${R} vs ${Y}You [code-reviewer]${R})"
echo ""

_INT_LAST_SEEN=0

while true; do
    IFS= read -e -p "$(_agent_prompt)" -r input || {
        # read returned non-zero. Two reasons:
        #   (1) SIGINT (Ctrl+C): the trap wrote a timestamp to $_INT_TS_FILE
        #   (2) EOF (Ctrl+D on empty line)
        # For (1), use double-tap-to-exit: first press shows a hint, second
        # press within $_INT_WINDOW seconds actually exits. For (2), exit
        # cleanly — that's the documented way out.
        if [[ -f "$_INT_TS_FILE" ]]; then
            _now=$(date +%s)
            _last=$(cat "$_INT_TS_FILE" 2>/dev/null || echo 0)
            rm -f "$_INT_TS_FILE"
            if (( _now - _last <= 1 )) \
               && (( _INT_LAST_SEEN > 0 )) \
               && (( _now - _INT_LAST_SEEN <= _INT_WINDOW )); then
                # Double-tap: actually exit
                echo
                history -w 2>/dev/null || true
                exit 0
            fi
            # First press: read already discarded the line, just show hint
            _INT_LAST_SEEN=$_last
            warn "(Ctrl+C — line cleared. Type /exit, press Ctrl+D, or Ctrl+C again within ${_INT_WINDOW}s to quit.)"
            input=""
            continue
        fi
        # EOF (Ctrl+D on empty line) or some other read error
        echo
        history -w 2>/dev/null || true
        exit 0
    }
    # A successful read resets the double-tap window
    _INT_LAST_SEEN=0
    rm -f "$_INT_TS_FILE" 2>/dev/null || true
    input="${input%"${input##*[![:space:]]}"}"
    [[ -z "$input" ]] && continue
    history -s "$input"

    case "$input" in
        /exit) exit 0 ;;
        /reload) history -w 2>/dev/null || true; exec bash "$0" ;;
        /help) help; continue ;;
        /agents)
            list_agents
            continue
            ;;
        /agents\ *)
            filter="${input#/agents }"
            filter="${filter#@}"
            filter="${filter% }"
            if [[ -z "$filter" ]]; then
                warn "usage: /agents [@tag]"
            else
                list_agents "$filter"
            fi
            continue
            ;;
        /agent*)
            if [[ "$input" == "/agent" ]]; then
                agent_status
            elif [[ "$input" == "/agent reload" ]]; then
                SYSTEM_PROMPT="$(load_system_prompt)"
                init_db
                init_team_db
                prune_history
                load_history
                load_tools
                ok "Agent reloaded"
            else
                arg="${input#/agent }"
                arg="${arg% }"
                if [[ -n "$arg" && "$arg" =~ ^[0-9]+$ ]]; then
                    resolved=$(_resolve_agent_id "$arg") || {
                        warn "no agent with id $arg (try /agents to list)"
                        continue
                    }
                    arg="$resolved"
                fi
                if [[ -n "$arg" ]]; then
                    if switch_agent "$arg"; then
                        ok "Switched to: $arg"
                    else
                        list_agents 2>/dev/null
                    fi
                else
                    agent_status
                fi
            fi
            continue
            ;;
        /clear)
            history_messages="[]"
            sql "DELETE FROM messages"
            info "History cleared."
            continue
            ;;
        /board)
            # Topic summary table (existing behavior). Shows count + last
            # write per topic, ordered by most-recent first.
            sqlite3 -header -column "$AI_AGENT_DB" \
                "SELECT topic, COUNT(*) AS msgs, MAX(created_at) AS last FROM board GROUP BY topic ORDER BY last DESC" 2>/dev/null \
                || info "blackboard is empty"
            continue
            ;;
        /board\ write\ *)
            # /board write <topic> <payload...>
            # Topic is the first whitespace-delimited token; the REST of
            # the input is the payload (may contain spaces, including
            # multi-line via $'...' on the shell side).
            _arg="${input#/board write }"
            _topic="${_arg%% *}"
            _payload="${_arg#"$_topic"}"
            _payload="${_payload# }"   # strip leading single space
            if [[ -z "$_topic" || -z "$_payload" ]]; then
                warn "usage: /board write <topic> <payload>"
                continue
            fi
            _j_topic=$(printf '%s' "$_topic"  | jq -Rsr 'if . == "" then "\"\"" else @json end')
            _j_pl=$(printf '%s' "$_payload"   | jq -Rsr 'if . == "" then "\"\"" else @json end')
            _out=$(AGENT_NAME="$CURRENT_AGENT" AI_AGENT_DB="$AI_AGENT_DB" \
                sh "$TOOLS_DIR/board_write.sh" \
                "{\"topic\":${_j_topic},\"payload\":${_j_pl}}" 2>&1)
            if printf '%s' "$_out" | jq -e '.success' >/dev/null 2>&1; then
                _id=$(printf '%s' "$_out" | jq -r '.id')
                ok "board write ok: id=$_id topic=$_topic"
            else
                warn "board write failed: $_out"
            fi
            continue
            ;;
        /board\ reply\ *)
            # /board reply <id> <payload...>  →  INSERT with reply_to=id
            _arg="${input#/board reply }"
            _id="${_arg%% *}"
            _payload="${_arg#"$_id"}"
            _payload="${_payload# }"
            if [[ -z "$_id" || -z "$_payload" ]] || ! [[ "$_id" =~ ^[0-9]+$ ]]; then
                warn "usage: /board reply <id> <payload>"
                continue
            fi
            # Look up the source entry's topic to use the same topic.
            # Falls back to "replies" if the source id is missing.
            _topic=$(bb_sql "SELECT topic FROM board WHERE id = $_id" | tail -1)
            [[ -z "$_topic" ]] && _topic="replies"
            _j_topic=$(printf '%s' "$_topic"  | jq -Rsr 'if . == "" then "\"\"" else @json end')
            _j_pl=$(printf '%s' "$_payload"   | jq -Rsr 'if . == "" then "\"\"" else @json end')
            _out=$(AGENT_NAME="$CURRENT_AGENT" AI_AGENT_DB="$AI_AGENT_DB" \
                sh "$TOOLS_DIR/board_write.sh" \
                "{\"topic\":${_j_topic},\"payload\":${_j_pl},\"reply_to\":${_id}}" 2>&1)
            if printf '%s' "$_out" | jq -e '.success' >/dev/null 2>&1; then
                _nid=$(printf '%s' "$_out" | jq -r '.id')
                ok "board reply ok: id=$_nid reply_to=$_id topic=$_topic"
            else
                warn "board reply failed: $_out"
            fi
            continue
            ;;
        /board\ clear\ *)
            # /board clear <topic> [-y]
            # Bare = soft (rename topic to "[cleared] <topic>").  -y = hard
            # (DELETE all rows for that topic — irreversible).  Mirrors
            # the /task clear semantics so the mental model is uniform.
            _arg="${input#/board clear}"
            _arg="${_arg# }"
            _topic="${_arg%% *}"
            _rest="${_arg#"$_topic"}"
            _rest="${_rest# }"
            _rest="${_rest% }"
            _hard="false"
            if [[ "$_rest" == "-y" || "$_rest" == "--yes" ]]; then
                _hard="true"
            elif [[ -n "$_rest" ]]; then
                warn "usage: /board clear <topic> [-y]"
                continue
            fi
            if [[ -z "$_topic" ]]; then
                warn "usage: /board clear <topic> [-y]"
                continue
            fi
            _j_topic=$(printf '%s' "$_topic" | jq -Rsr 'if . == "" then "\"\"" else @json end')
            if [[ "$_hard" == "true" ]]; then
                _out=$(AGENT_NAME="$CURRENT_AGENT" AI_AGENT_DB="$AI_AGENT_DB" \
                    sh "$TOOLS_DIR/board_clear.sh" \
                    "{\"topic\":${_j_topic},\"yes\":true}" 2>&1)
            else
                # Show impact first (count) for the soft path so the user
                # can decide whether to -y it.  Skip in non-TTY (tests).
                _n=$(bb_sql "SELECT COUNT(*) FROM board WHERE topic = $(bb_quote "$_topic")" | tail -1)
                if [[ -z "$_n" || "$_n" == "0" ]]; then
                    info "board clear: no entries for topic '$_topic'"
                    continue
                fi
                if [[ -t 0 ]]; then
                    read -r -p "soft-clear '$_topic' ($_n entries) — type 'yes' to confirm: " _ans
                    if [[ "$_ans" != "yes" ]]; then
                        info "aborted"
                        continue
                    fi
                fi
                _out=$(AGENT_NAME="$CURRENT_AGENT" AI_AGENT_DB="$AI_AGENT_DB" \
                    sh "$TOOLS_DIR/board_clear.sh" \
                    "{\"topic\":${_j_topic}}" 2>&1)
            fi
            if printf '%s' "$_out" | jq -e '.success' >/dev/null 2>&1; then
                _mode=$(printf '%s' "$_out" | jq -r '.mode')
                _aff=$(printf '%s' "$_out" | jq -r '.affected // .deleted // 0')
                ok "board clear ok: mode=$_mode topic=$_topic affected=$_aff"
            else
                warn "board clear failed: $_out"
            fi
            continue
            ;;
        /board\ topics*)
            # /board topics [prefix] — uses the board_list tool so the
            # tool path stays the source of truth.
            _arg="${input#/board topics}"
            _arg="${_arg# }"
            _arg="${_arg% }"
            if [[ -n "$_arg" ]]; then
                _j=$(printf '%s' "$_arg" | jq -Rsr 'if . == "" then "\"\"" else @json end')
                _out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/board_list.sh" "{\"prefix\":${_j}}")
            else
                _out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/board_list.sh" '{}')
            fi
            if [[ -z "$_out" || "$_out" == "[]" ]]; then
                info "no topics"
            else
                printf '%s\n' "$_out" | jq -r '.[] | (if type == "object" then .topic else . end)' | sed 's/^/  /'
            fi
            continue
            ;;
        /board\ grep\ *)
            # /board grep <pattern>  — LIKE search across ALL topics'
            # payloads.  Useful when you don't remember the topic name.
            #   - Pattern is SQL LIKE syntax: % wildcard, _ single char
            #   - Outputs id, agent, topic, snippet (first 80 chars)
            _pat="${input#/board grep }"
            _pat="${_pat% }"
            if [[ -z "$_pat" ]]; then
                warn "usage: /board grep <pattern>  (SQL LIKE: % = any)"
                continue
            fi
            _j=$(printf '%s' "$_pat" | jq -Rsr 'if . == "" then "\"\"" else @json end')
            # We can run board_list once for topic discovery, then
            # per-topic LIKE search.  Simpler: one cross-topic SQL.
            _esc=$(printf '%s' "$_pat" | sed "s/'/''/g")
            echo "== grep '$_pat' =="
            _hits=$(sqlite3 -header -column "$AI_AGENT_DB" \
                "SELECT id, agent, topic, substr(payload,1,80) AS snippet, created_at FROM board WHERE payload LIKE '%$_esc%' ORDER BY id" 2>/dev/null)
            if [[ -z "$_hits" ]]; then
                info "no matches"
            else
                printf '%s\n' "$_hits"
            fi
            continue
            ;;
        /board\ stat)
            # /board stat — overall dashboard
            echo "== board stat =="
            sqlite3 -header -column "$AI_AGENT_DB" \
                "SELECT 'total entries' AS metric, COUNT(*) AS value FROM board
                 UNION ALL SELECT 'distinct topics', COUNT(DISTINCT topic) FROM board
                 UNION ALL SELECT 'agents (with entries)', COUNT(DISTINCT NULLIF(agent,'')) FROM board
                 UNION ALL SELECT 'replies (reply_to IS NOT NULL)', COUNT(*) FROM board WHERE reply_to IS NOT NULL
                 UNION ALL SELECT 'earliest entry', MIN(created_at) FROM board
                 UNION ALL SELECT 'latest entry', MAX(created_at) FROM board" 2>/dev/null \
                || info "blackboard is empty"
            echo ""
            echo "-- by agent --"
            sqlite3 -header -column "$AI_AGENT_DB" \
                "SELECT agent, COUNT(*) AS entries, COUNT(DISTINCT topic) AS topics FROM board GROUP BY agent ORDER BY entries DESC" 2>/dev/null \
                || true
            continue
            ;;
        /board\ *)
            # /board <topic> [opts...] [<id>]
            #   --since <id>  show only entries with id > N
            #   -n <N>        limit (default 50, max 500)
            #   <id>          show one entry in full (overrides list mode)
            # The first token is always the topic.
            _arg="${input#/board }"
            _arg="${_arg% }"
            _topic="${_arg%% *}"
            _rest="${_arg#"$_topic"}"
            _rest="${_rest# }"
            _since=0
            _limit=50
            _single_id=""
            # Parse _rest in a loop so flags can come in any order.
            while [[ -n "$_rest" ]]; do
                _tok="${_rest%% *}"
                _rest="${_rest#"$_tok"}"
                _rest="${_rest# }"
                case "$_tok" in
                    --since)
                        _next="${_rest%% *}"
                        _rest="${_rest#"$_next"}"
                        _rest="${_rest# }"
                        if [[ "$_next" =~ ^[0-9]+$ ]]; then
                            _since="$_next"
                        else
                            warn "--since expects an integer id, got '$_next'"
                            continue 2
                        fi
                        ;;
                    -n)
                        _next="${_rest%% *}"
                        _rest="${_rest#"$_next"}"
                        _rest="${_rest# }"
                        if [[ "$_next" =~ ^[0-9]+$ ]] && (( _next >= 1 )) && (( _next <= 500 )); then
                            _limit="$_next"
                        else
                            warn "-n expects 1..500, got '$_next'"
                            continue 2
                        fi
                        ;;
                    -*)
                        warn "unknown /board flag: $_tok"
                        continue 2
                        ;;
                    *)
                        # Bare number = single-id request
                        if [[ "$_tok" =~ ^[0-9]+$ ]] && [[ -z "$_single_id" ]]; then
                            _single_id="$_tok"
                        else
                            warn "unexpected extra arg: $_tok"
                            continue 2
                        fi
                        ;;
                esac
            done
            if [[ -n "$_single_id" ]]; then
                # Show one entry in full
                echo "== board entry id=$_single_id =="
                sqlite3 -header -line "$AI_AGENT_DB" \
                    "SELECT id, agent, topic, reply_to, payload, created_at FROM board WHERE id = $_single_id" 2>/dev/null \
                    || warn "no entry with id=$_single_id"
                continue
            fi
            # List mode (composed: --since + -n)
            echo "== board topic='$_topic' since=$_since limit=$_limit =="
            _j_t=$(printf '%s' "$_topic" | jq -Rsr 'if . == "" then "\"\"" else @json end')
            _out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/board_read.sh" \
                "{\"topic\":${_j_t},\"since_id\":${_since},\"limit\":${_limit}}" 2>/dev/null)
            if [[ -z "$_out" || "$_out" == "[]" ]]; then
                info "no entries"
            else
                printf '%s\n' "$_out" \
                    | jq -r '.[] | "[\(.id)] \(.created_at) \(.agent|if . == "" then "_" else . end) rt=\(.reply_to // 0)\n  \(.payload)"'
            fi
            continue
            ;;
        /tasks)
            init_team_db
            _list_tasks_out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/task_list.sh" '{}' | jq -r '.[] | "[\(.id) \(.status|tostring|.[0:4])/\(.type)] \(.assigned_to|if . == "" then "_" else . end) p=\(.priority) \(.title)"' 2>/dev/null)
            if [[ -z "$_list_tasks_out" ]]; then info "no tasks"; else echo "$_list_tasks_out"; fi
            continue
            ;;
        /tasks\ ready)
            init_team_db
            _list_tasks_out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/task_list.sh" '{"ready":1}' | jq -r '.[] | "[\(.id) \(.status|tostring|.[0:4])/\(.type)] \(.assigned_to|if . == "" then "_" else . end) p=\(.priority) \(.title)"' 2>/dev/null)
            if [[ -z "$_list_tasks_out" ]]; then info "no ready tasks"; else echo "$_list_tasks_out"; fi
            continue
            ;;
        /tasks\ *)
            arg="${input#/tasks }"
            arg="${arg% }"
            init_team_db
            _list_tasks_out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/task_list.sh" "{\"status\":\"$arg\"}" | jq -r '.[] | "[\(.id) \(.status|tostring|.[0:4])/\(.type)] \(.assigned_to|if . == "" then "_" else . end) p=\(.priority) \(.title)"' 2>/dev/null)
            if [[ -z "$_list_tasks_out" ]]; then info "no tasks with status '$arg'"; else echo "$_list_tasks_out"; fi
            continue
            ;;
        /task)
            warn "usage: /task <id>"
            continue
            ;;
        /task\ clear*)
            # /task clear         — soft-cancel non-done tasks (rows + done + audit preserved)
            # /task clear -y      — HARD full-wipe: delete ALL task rows + ALL events (incl. done)
            # In both modes, team_state.goal is untouched.
            # The -y flag is the explicit "yes, I really want to wipe everything" opt-in;
            # without it, the operation is the safe soft-cancel (idempotent, audit-preserving).
            arg="${input#/task clear}"
            arg="${arg# }"
            arg="${arg% }"
            if [[ "$arg" != "-y" && "$arg" != "--yes" && -n "$arg" ]]; then
                warn "usage: /task clear [-y|--yes]"
                continue
            fi
            init_team_db
            _tc_total=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks" 2>/dev/null)
            _tc_canc=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('pending','claimed','in_progress','review','blocked')" 2>/dev/null)
            _tc_done=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks WHERE status='done'" 2>/dev/null)
            _tc_already_canc=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks WHERE status='cancelled'" 2>/dev/null)
            if [[ "${_tc_total:-0}" -eq 0 ]]; then
                ok "task queue already empty"
                continue
            fi
            if [[ "$arg" == "-y" || "$arg" == "--yes" ]]; then
                # HARD full-wipe: prompts in TTY because it's destructive
                if [[ -t 0 ]]; then
                    _ans=""
                    read -r -p "HARD WIPE: delete ALL $_tc_total task(s) + their events (incl. $_tc_done done, $_tc_already_canc cancelled)? [y/N] " _ans
                    if [[ ! "$_ans" =~ ^[Yy]$ ]]; then
                        ok "task clear aborted (no changes)"
                        continue
                    fi
                fi
                _task_clear_out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/task_clear.sh" '{"yes":true}' 2>&1)
                if echo "$_task_clear_out" | jq -e '.success' >/dev/null 2>&1; then
                    _c=$(echo "$_task_clear_out" | jq -r '.deleted')
                    _e=$(echo "$_task_clear_out" | jq -r '.events_deleted')
                    ok "FULL WIPE: deleted $_c task(s) + $_e event(s); goal untouched"
                else
                    warn "task clear failed: $(echo "$_task_clear_out" | jq -r '.error // "unknown"')"
                fi
            else
                if [[ "${_tc_canc:-0}" -eq 0 ]]; then
                    ok "nothing to soft-cancel ($_tc_done done + $_tc_already_canc cancelled kept, goal untouched)"
                    continue
                fi
                # Soft cancel: prompt only in TTY (safe + idempotent)
                if [[ -t 0 ]]; then
                    _ans=""
                    read -r -p "soft-cancel $_tc_canc task(s) (flip to 'cancelled', keep $_tc_done done, keep goal)? [y/N] " _ans
                    if [[ ! "$_ans" =~ ^[Yy]$ ]]; then
                        ok "task clear aborted (no changes)"
                        continue
                    fi
                fi
                _task_clear_out=$(AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/task_clear.sh" '{}' 2>&1)
                if echo "$_task_clear_out" | jq -e '.success' >/dev/null 2>&1; then
                    _c=$(echo "$_task_clear_out" | jq -r '.deleted')
                    _d=$(echo "$_task_clear_out" | jq -r '.preserved_done')
                    _k=$(echo "$_task_clear_out" | jq -r '.preserved_cancelled')
                    ok "cancelled $_c task(s); kept $_d done + $_k cancelled; goal untouched"
                else
                    warn "task clear failed: $(echo "$_task_clear_out" | jq -r '.error // "unknown"')"
                fi
            fi
            continue
            ;;
        /task\ *)
            arg="${input#/task }"
            arg="${arg% }"
            if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
                warn "usage: /task <id>"
                continue
            fi
            init_team_db
            AI_AGENT_DB="$AI_AGENT_DB" sh "$TOOLS_DIR/task_show.sh" "{\"task_id\":$arg}" | jq -r '
                if .success then
                    (.task as $t |
                     [$t.id, $t.status, $t.title, ($t.depends_on // ""), ($t.description // ""), ($t.result // ""), ($t.artifacts // ""), $t.assigned_to, $t.priority, $t.type, (.events | length)] as $h |
                     ([
                        "ID \($h[0]) [\($h[1])] type=\($h[9]) assignee=\(if ($h[7] // "") == "" then "-" else $h[7] end) priority=\($h[8])",
                        "title:   \($h[2])",
                        "deps:    \(if $h[3] == "" then "-" else $h[3] end)",
                        "desc:    \($h[4])",
                        (if $h[5] != "" then "result:  \($h[5])" else empty end),
                        (if $h[6] != "" then "artifacts: \($h[6])" else empty end),
                        "events (\($h[10])):"
                     ] + [.events[] | "  \(.created_at) [\(.event)]\(if .agent != "" then " by \(.agent)" else "" end)\(if .message != "" then ": \(.message)" else "" end)"]) | join("\n"))
                else
                    "error: \(.error)"
                end'
            continue
            ;;
        /team)
            init_team_db
            _team_status
            continue
            ;;
        /team\ status)
            init_team_db
            _team_status
            continue
            ;;
        /team\ start\ *)
            arg="${input#/team start }"
            arg="${arg% }"
            _team_start "$arg" || warn "team start failed"
            continue
            ;;
        /team\ next)
            init_team_db
            _team_next || warn "team next failed"
            continue
            ;;
        /team\ stop)
            init_team_db
            _team_stop || warn "team stop failed"
            continue
            ;;
        /team\ clear|/team\ clear\ *)
            init_team_db
            arg="${input#/team clear}"
            arg="${arg# }"
            case "$arg" in
                "") _team_clear || warn "team clear failed" ;;
                -y|--yes) _team_clear y || warn "team clear failed" ;;
                *) warn "usage: /team clear [-y|--yes]" ;;
            esac
            continue
            ;;
        /hist\ *)
            hist_arg="${input#/hist }"
            hist_arg="${hist_arg% }"
            if [[ "$hist_arg" == "full" ]]; then
                _hist_full || true
            elif [[ "$hist_arg" =~ ^full\ [0-9]+$ ]]; then
                _hist_full "${hist_arg#full }" || true
            elif [[ "$hist_arg" =~ ^[0-9]+$ ]]; then
                _hist_one "$hist_arg" || true
            else
                warn "usage: /hist | /hist full | /hist full <id> | /hist <id>"
            fi
            continue
            ;;
        /hist)
            _agent=$(chat_table_id)
            echo "== messages (agent=$_agent) =="
            sqlite3 -header -column "$AI_AGENT_DB" "SELECT id, role, substr(COALESCE(content,'<null>'),1,60) as content, COALESCE(raw_input,'') as raw_input, CASE WHEN thinking IS NULL THEN '' ELSE length(thinking) || ' chars' END as thinking FROM messages WHERE agent_id='$(printf "%s" "$_agent" | sed "s/'/''/g")' ORDER BY id" 2>/dev/null || echo "No messages"
            echo
            echo "== tool_calls (agent=$_agent) =="
            sqlite3 -header -column "$AI_AGENT_DB" "SELECT id, message_id, name, substr(COALESCE(arguments,'{}'),1,40) as arguments, length(COALESCE(result,'')) as result_len FROM tool_calls WHERE agent_id='$(printf "%s" "$_agent" | sed "s/'/''/g")' ORDER BY message_id, rowid" 2>/dev/null || echo "No tool calls"
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
        /*)
            # Unknown slash command. Try to suggest the closest match(es)
            # via Levenshtein; if nothing is close enough, fall back to
            # /help. Either way, NEVER fall through to the LLM for a bare
            # /-command — the user clearly meant a built-in.
            _suggested=$(_suggest_command "$input" 3) || _suggested=""
            if [[ -n "$_suggested" ]]; then
                warn "unknown command: $input"
                warn "did you mean:"
                _i=1
                while IFS= read -r _s; do
                    [[ -z "$_s" ]] && continue
                    warn "  $_i. $_s"
                    _i=$((_i+1))
                done <<< "$_suggested"
            else
                warn "unknown command: $input"
                warn "no similar command found — showing /help"
                help
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
