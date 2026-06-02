#!/usr/bin/env bash
set -euo pipefail
WORK_DIR="$(dirname $0)"

AI_AGENT_VERSION="0.1.0"

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
BLACKBOARD_DB="$DATA_DIR/blackboard.db"
MAX_HISTORY=40

R='\033[0m'; B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'; D='\033[2m'; DM='\033[90m'

mkdir -p "$DATA_DIR" "$TEMP_DIR"

db_path() {
    if [[ -z "$CURRENT_AGENT" ]]; then
        echo "$DATA_DIR/chat.db"
    else
        echo "$DATA_DIR/chat_${CURRENT_AGENT}.db"
    fi
}

load_system_prompt() {
    if [[ -n "$CURRENT_AGENT" ]]; then
        cat "$AGENTS_DIR/$CURRENT_AGENT/system.md" 2>/dev/null
    else
        cat "${WORK_DIR}/SYSTEM_PROMPT.md" 2>/dev/null
    fi
}

if [[ -f "$CURRENT_AGENT_FILE" ]]; then
    _candidate=$(cat "$CURRENT_AGENT_FILE" 2>/dev/null) || _candidate=""
    if [[ "$_candidate" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ -f "$AGENTS_DIR/$_candidate/system.md" ]]; then
        CURRENT_AGENT="$_candidate"
    else
        rm -f "$CURRENT_AGENT_FILE" 2>/dev/null || true
    fi
fi

DB_PATH=$(db_path)
TOOLS_CACHE="$DATA_DIR/tools_cache${CURRENT_AGENT:+_$CURRENT_AGENT}.json"
TOOLS_DESC_CACHE="$DATA_DIR/tools_desc${CURRENT_AGENT:+_$CURRENT_AGENT}.txt"

trap 'history -w 2>/dev/null || true' EXIT
trap 'echo; history -w 2>/dev/null || true; exit 0' INT

DB_PATH=$(db_path)
TOOLS_CACHE="$DATA_DIR/tools_cache${CURRENT_AGENT:+_$CURRENT_AGENT}.json"
TOOLS_DESC_CACHE="$DATA_DIR/tools_desc${CURRENT_AGENT:+_$CURRENT_AGENT}.txt"

trap 'history -w 2>/dev/null || true' EXIT
trap 'echo; history -w 2>/dev/null || true; exit 0' INT

_hist_full() {
    local target_id="${1:-}"
    local where=""
    if [[ -n "$target_id" ]]; then
        if ! [[ "$target_id" =~ ^[0-9]+$ ]]; then
            warn "id must be numeric: $target_id"
            return 1
        fi
        where=" WHERE id=$target_id"
    fi
    local n_msgs n_tcs
    n_msgs=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages$where" 2>/dev/null)
    n_tcs=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tool_calls${where/tool_calls/messages}" 2>/dev/null)
    if [[ -n "$target_id" ]]; then
        echo "== full message #$target_id =="
    else
        echo "== full history ($n_msgs messages, $n_tcs tool_calls) =="
    fi
    if [[ -z "$n_msgs" || "$n_msgs" == "0" ]]; then
        if [[ -n "$target_id" ]]; then
            warn "no message with id=$target_id"
            return 1
        fi
        echo "(no messages)"
        return
    fi
    local sep="----------------------------------------"
    local id role content raw_input thinking has_tc
    local ids
    ids=$(sqlite3 "$DB_PATH" "SELECT id FROM messages$where ORDER BY id" 2>/dev/null)
    for id in $ids; do
        role=$(sqlite3 "$DB_PATH" "SELECT role FROM messages WHERE id=$id" 2>/dev/null)
        content=$(sqlite3 "$DB_PATH" "SELECT content FROM messages WHERE id=$id" 2>/dev/null)
        raw_input=$(sqlite3 "$DB_PATH" "SELECT COALESCE(raw_input,'') FROM messages WHERE id=$id" 2>/dev/null)
        thinking=$(sqlite3 "$DB_PATH" "SELECT COALESCE(thinking,'') FROM messages WHERE id=$id" 2>/dev/null)
        has_tc=$(sqlite3 "$DB_PATH" "SELECT CASE WHEN EXISTS(SELECT 1 FROM tool_calls WHERE message_id=$id) THEN 1 ELSE 0 END" 2>/dev/null)
        echo "$sep"
        echo "#$id  role=$role  has_tool_calls=$has_tc"
        if [[ -n "$content" ]]; then
            echo "[content]"
            echo "$content"
        fi
        if [[ -n "$raw_input" ]]; then
            echo "[raw_input]"
            echo "$raw_input"
        fi
        if [[ -n "$thinking" ]]; then
            echo "[thinking]"
            echo "$thinking"
        fi
        if [[ "$has_tc" == "1" ]]; then
            local tc_ids tc_id tc_name tc_args tc_result
            tc_ids=$(sqlite3 "$DB_PATH" "SELECT id FROM tool_calls WHERE message_id=$id ORDER BY rowid" 2>/dev/null)
            for tc_id in $tc_ids; do
                tc_name=$(sqlite3 "$DB_PATH" "SELECT name FROM tool_calls WHERE id='$tc_id'" 2>/dev/null)
                tc_args=$(sqlite3 "$DB_PATH" "SELECT arguments FROM tool_calls WHERE id='$tc_id'" 2>/dev/null)
                tc_result=$(sqlite3 "$DB_PATH" "SELECT COALESCE(result,'') FROM tool_calls WHERE id='$tc_id'" 2>/dev/null)
                [[ -z "$tc_name" ]] && tc_name="(unnamed)"
                echo "  tool: $tc_name  id=$tc_id"
                echo "  [arguments]"
                echo "$tc_args" | sed 's/^/    /'
                if [[ -n "$tc_result" ]]; then
                    echo "  [result]"
                    echo "$tc_result" | sed 's/^/    /'
                fi
            done
        fi
    done
    echo "$sep"
}

_hist_one() {
    local id="$1"
    local role content raw_input thinking
    role=$(sqlite3 "$DB_PATH" "SELECT role FROM messages WHERE id=$id" 2>/dev/null)
    if [[ -z "$role" ]]; then
        warn "no message with id=$id"
        return 1
    fi
    content=$(sqlite3 "$DB_PATH" "SELECT content FROM messages WHERE id=$id" 2>/dev/null)
    raw_input=$(sqlite3 "$DB_PATH" "SELECT COALESCE(raw_input,'') FROM messages WHERE id=$id" 2>/dev/null)
    thinking=$(sqlite3 "$DB_PATH" "SELECT COALESCE(thinking,'') FROM messages WHERE id=$id" 2>/dev/null)
    echo "== message #$id =="
    echo "role: $role"
    if [[ -n "$content" ]]; then
        echo
        echo "[content]"
        echo "$content"
    fi
    if [[ -n "$raw_input" ]]; then
        echo
        echo "[raw_input]"
        echo "$raw_input"
    fi
    if [[ -n "$thinking" ]]; then
        echo
        echo "[thinking]"
        echo "$thinking"
    fi
    local tc_ids tc_id tc_name tc_args tc_result
    tc_ids=$(sqlite3 "$DB_PATH" "SELECT id FROM tool_calls WHERE message_id=$id ORDER BY rowid" 2>/dev/null)
    if [[ -n "$tc_ids" ]]; then
        for tc_id in $tc_ids; do
            tc_name=$(sqlite3 "$DB_PATH" "SELECT name FROM tool_calls WHERE id='$tc_id'" 2>/dev/null)
            tc_args=$(sqlite3 "$DB_PATH" "SELECT arguments FROM tool_calls WHERE id='$tc_id'" 2>/dev/null)
            tc_result=$(sqlite3 "$DB_PATH" "SELECT COALESCE(result,'') FROM tool_calls WHERE id='$tc_id'" 2>/dev/null)
            [[ -z "$tc_name" ]] && tc_name="(unnamed)"
            echo
            echo "tool: $tc_name  id=$tc_id"
            echo "  [arguments]"
            echo "$tc_args" | sed 's/^/    /'
            if [[ -n "$tc_result" ]]; then
                echo "  [result]"
                echo "$tc_result" | sed 's/^/    /'
            fi
        done
    fi
}

SYSTEM_PROMPT="$(load_system_prompt)"

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

init_blackboard() {
    sqlite3 "$BLACKBOARD_DB" <<'SQL' || true
        CREATE TABLE IF NOT EXISTS board (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            agent       TEXT NOT NULL DEFAULT '',
            topic       TEXT NOT NULL,
            payload     TEXT NOT NULL,
            reply_to    INTEGER,
            created_at  TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_board_topic ON board(topic);
        CREATE INDEX IF NOT EXISTS idx_board_reply ON board(reply_to);
SQL
}
bb_sql() { sqlite3 "$BLACKBOARD_DB" <<< "$1" || true; }
bb_quote() {
    local q s
    q="''"
    s="${1//\'/$q}"
    printf "'%s'" "$s"
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
    AGENT_NAME="$CURRENT_AGENT" BLACKBOARD_DB_PATH="$BLACKBOARD_DB" \
    WORK_DIR="$WORK_DIR" AGENTS_DIR="$AGENTS_DIR" \
    DELEGATION_DEPTH="${DELEGATION_DEPTH:-0}" \
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
    echo "  /hist             - Show recent history (summary view)
  /hist full        - Show every message + tool_call in full
  /hist full <id>   - Show one message in full style + its tool calls
  /hist <id>        - Show one message (full content) + its tool calls"
    echo "  /tools            - List available tools"
    echo "  /tools reload     - Reload tools from $TOOLS_DIR"
    echo "  /agent            - Show current agent (name, db, msgs, tools)"
    echo "  /agent <name>     - Switch to named agent (or 'default')"
    echo "  /agent reload     - Reload current agent's prompt + tools"
    echo "  /agents           - List all available agents (with description and tags)
  /agents @tag      - List agents whose frontmatter tags include @tag"
    echo "  /board [topic]    - List blackboard topics or show entries for a topic"
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

list_agents() {
    local filter_tag="${1:-}"
    local marker name desc tags d found=0
    if [[ -z "$CURRENT_AGENT" ]]; then marker="*"; else marker=" "; fi
    desc=$(agent_description "${WORK_DIR}/SYSTEM_PROMPT.md")
    [[ -z "$desc" ]] && desc="(no description)"
    tags=$(agent_tags "${WORK_DIR}/SYSTEM_PROMPT.md")
    if _agent_matches_tag "$tags" "$filter_tag"; then
        _print_agent_line "default" "$desc" "$tags" "$marker"
        found=1
    fi
    if [[ -d "$AGENTS_DIR" ]]; then
        for d in "$AGENTS_DIR"/*/; do
            [[ -d "$d" ]] || continue
            name=$(basename "$d")
            [[ ! -f "$d/system.md" ]] && continue
            desc=$(agent_description "$d/system.md")
            [[ -z "$desc" ]] && desc="(no description)"
            tags=$(agent_tags "$d/system.md")
            if [[ "$name" == "$CURRENT_AGENT" ]]; then marker="*"; else marker=" "; fi
            if _agent_matches_tag "$tags" "$filter_tag"; then
                _print_agent_line "$name" "$desc" "$tags" "$marker"
                found=1
            fi
        done
    fi
    if [[ $found -eq 0 && -n "$filter_tag" ]]; then
        warn "no agents match tag @$filter_tag"
    fi
}

switch_agent() {
    local name="$1"
    local target_agent="" target_prompt=""

    if [[ -z "$name" || "$name" == "default" ]]; then
        target_prompt="${WORK_DIR}/SYSTEM_PROMPT.md"
        if [[ ! -f "$target_prompt" ]]; then
            warn "default system prompt not found: $target_prompt"
            return 1
        fi
    else
        if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            warn "invalid agent name: $name"
            return 1
        fi
        target_agent="$name"
        target_prompt="$AGENTS_DIR/$name/system.md"
        if [[ ! -f "$target_prompt" ]]; then
            warn "agent '$name' not found (missing $target_prompt)"
            return 1
        fi
    fi

    CURRENT_AGENT="$target_agent"

    if [[ -n "$CURRENT_AGENT" ]]; then
        printf '%s' "$CURRENT_AGENT" > "$CURRENT_AGENT_FILE"
    else
        rm -f "$CURRENT_AGENT_FILE" 2>/dev/null || true
    fi

    DB_PATH=$(db_path)
    TOOLS_CACHE="$DATA_DIR/tools_cache${CURRENT_AGENT:+_$CURRENT_AGENT}.json"
    TOOLS_DESC_CACHE="$DATA_DIR/tools_desc${CURRENT_AGENT:+_$CURRENT_AGENT}.txt"

    SYSTEM_PROMPT="$(load_system_prompt)"

    init_db
    prune_history
    load_history
    load_tools

    return 0
}

agent_status() {
    local cur msgs_n tools_n
    if [[ -z "$CURRENT_AGENT" ]]; then cur="default"; else cur="$CURRENT_AGENT"; fi
    msgs_n=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages" 2>/dev/null || echo 0)
    tools_n=$(echo "$tools_json" | jq 'length' 2>/dev/null || echo 0)
    local desc tags f
    if [[ -n "$CURRENT_AGENT" ]]; then f="$AGENTS_DIR/$CURRENT_AGENT/system.md"; else f="${WORK_DIR}/SYSTEM_PROMPT.md"; fi
    desc=$(agent_description "$f")
    tags=$(agent_tags "$f")
    printf 'name=%s\n' "$cur"
    [[ -n "$desc" ]] && printf 'description=%s\n' "$desc"
    [[ -n "$tags" ]] && printf 'tags=%s\n' "$tags"
    printf 'db=%s msgs=%s tools=%s\n' "$DB_PATH" "$msgs_n" "$tools_n"
}

parse_frontmatter() {
    local file="$1"
    FM_DESC=""
    FM_TAGS=""
    [[ ! -f "$file" ]] && return 1
    local in_fm=0 line key val
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            ((in_fm++))
            [[ $in_fm -ge 2 ]] && break
            continue
        fi
        if [[ $in_fm -eq 1 && "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_-]*)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            case "$key" in
                description) FM_DESC="$val" ;;
                tags) FM_TAGS="$val" ;;
            esac
        fi
    done < <(head -20 "$file")
}

agent_description() {
    local file="$1"
    parse_frontmatter "$file"
    if [[ -n "$FM_DESC" ]]; then
        echo "$FM_DESC"
    else
        head -1 "$file" 2>/dev/null | sed 's/^# *//'
    fi
}

agent_tags() {
    local file="$1"
    parse_frontmatter "$file"
    echo "$FM_TAGS"
}

_agent_matches_tag() {
    local tags="$1" filter_tag="$2"
    if [[ -z "$filter_tag" ]]; then return 0; fi
    local IFS=','
    local t
    for t in $tags; do
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [[ -n "$t" && "$t" == "$filter_tag" ]] && return 0
    done
    return 1
}

_print_agent_line() {
    local name="$1" desc="$2" tags="$3" marker="$4"
    if [[ -n "$tags" ]]; then
        printf '%s %-20s %-44s [%s]\n' "$marker" "$name" "$desc" "$tags"
    else
        printf '%s %-20s %s\n' "$marker" "$name" "$desc"
    fi
}

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

    tools_json=$(echo "$tools_json" | jq -c 'map(select(.function.name != "exec_command" and .function.name != "agent_delegate"))' 2>/dev/null) || true
    tools_wire_json=$(echo "$tools_wire_json" | jq -c 'map(select(.function.name != "exec_command" and .function.name != "agent_delegate"))' 2>/dev/null) || true
    tool_descriptions=$(echo "$tool_descriptions" | grep -v -E '(^| )(exec_command|agent_delegate)\(' 2>/dev/null || true)

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
init_blackboard
prune_history
load_history
load_tools

if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
    run_non_interactive
    exit $?
fi

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
                prune_history
                load_history
                load_tools
                ok "Agent reloaded"
            else
                arg="${input#/agent }"
                arg="${arg% }"
                if switch_agent "$arg"; then
                    ok "Switched to: $arg"
                else
                    list_agents 2>/dev/null
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
            sqlite3 -header -column "$BLACKBOARD_DB" "SELECT topic, COUNT(*) as msgs, MAX(created_at) as last FROM board GROUP BY topic ORDER BY last DESC" 2>/dev/null || info "blackboard is empty"
            continue
            ;;
        /board\ *)
            arg="${input#/board }"
            arg="${arg% }"
            echo "== board topic='$arg' =="
            sqlite3 -header -column "$BLACKBOARD_DB" "SELECT id, agent, substr(payload,1,80) as payload, COALESCE(reply_to,'') as reply_to, created_at FROM board WHERE topic = $(bb_quote "$arg") ORDER BY id" 2>/dev/null || info "no entries"
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
