# lib/db.sh — Database primitives for ai-agent.sh
#
# Single unified SQLite database at $AI_AGENT_DB (default: .data/ai-agent.db).
# All four logical stores live in the same file:
#   - messages / tool_calls  (per-agent chat history, partitioned by agent_id)
#   - board                  (inter-agent blackboard)
#   - tasks / task_events    (team workflow queue + audit)
#   - team_state             (dispatcher state)
#
# Env var: $AI_AGENT_DB
#
# Provides:
#   - db_path:            echo unified path (kept for back-compat)
#   - chat_table_id:      echo the agent_id to use for chat operations
#   - next_chat_id:       compute next per-agent id (MAX(id)+1, starts at 1)
#   - load_system_prompt: read current agent's system.md
#   - _hist_full / _hist_one: /hist dumpers (per-agent)
#   - init_db:            create all tables in $AI_AGENT_DB (idempotent)
#   - sql:                run a SQL statement against $AI_AGENT_DB
#   - chat_sql:           alias for sql (named for clarity)
#   - board_sql:          alias for sql
#   - task_sql:           alias for sql
#   - db_quote / chat_quote / board_quote: SQL single-quote escape
#   - db_exec_returning:  insert assistant row, echo new per-agent id
#   - add_message:        insert user/system/assistant row
#   - save_assistant_tool_call: insert assistant + N tool_calls
#   - save_tool_result:   UPDATE tool_calls SET result WHERE agent_id+id
#   - load_history:       build JSON array of all chat messages (per-agent)
#   - prune_history:      keep last MAX_HISTORY messages (per-agent)
#
# Variables read at call time (must be set by caller before any function):
#   $WORK_DIR, $DATA_DIR, $AGENTS_DIR, $CURRENT_AGENT, $AI_AGENT_DB

# db_path — back-compat shim. The DB is now a single file; the per-agent
# isolation is enforced at the row level (agent_id column) inside that file.
db_path() {
    echo "${AI_AGENT_DB:-$DATA_DIR/ai-agent.db}"
}

# chat_table_id — the agent_id string used to partition chat rows.
# Empty CURRENT_AGENT means the "default" persona.
chat_table_id() {
    if [[ -z "$CURRENT_AGENT" ]]; then
        echo "default"
    else
        echo "$CURRENT_AGENT"
    fi
}

# next_chat_id — compute the next id for messages/tool_calls within the
# current agent's partition. Starts at 1 for any new agent.
next_chat_id() {
    local agent
    agent=$(chat_table_id)
    local n
    n=$(sqlite3 "$AI_AGENT_DB" "SELECT COALESCE(MAX(id), 0) + 1 FROM messages WHERE agent_id = $(db_quote "$agent")" 2>/dev/null | tail -1)
    if [[ -z "$n" || "$n" == "0" ]]; then
        echo 1
    else
        echo "$n"
    fi
}

load_system_prompt() {
    if [[ -n "$CURRENT_AGENT" ]]; then
        cat "$AGENTS_DIR/$CURRENT_AGENT/system.md" 2>/dev/null
    else
        cat "${WORK_DIR}/SYSTEM_PROMPT.md" 2>/dev/null
    fi
}

# _hist_full [target_id] — full per-agent history dump.
# target_id: optional message id within the current agent's partition.
_hist_full() {
    local target_id="${1:-}"
    local agent
    agent=$(chat_table_id)
    local where=" WHERE agent_id = $(db_quote "$agent")"
    if [[ -n "$target_id" ]]; then
        if ! [[ "$target_id" =~ ^[0-9]+$ ]]; then
            warn "id must be numeric: $target_id"
            return 1
        fi
        where="$where AND id=$target_id"
    fi
    local n_msgs n_tcs
    n_msgs=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM messages$where" 2>/dev/null)
    n_tcs=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM tool_calls${where/tool_calls/messages} AND tool_calls.agent_id = $(db_quote "$agent")" 2>/dev/null)
    if [[ -n "$target_id" ]]; then
        echo "== full message #$target_id =="
    else
        echo "== full history (agent=$agent: $n_msgs messages, $n_tcs tool_calls) =="
    fi
    if [[ -z "$n_msgs" || "$n_msgs" == "0" ]]; then
        if [[ -n "$target_id" ]]; then
            warn "no message with id=$target_id in agent=$agent"
            return 1
        fi
        echo "(no messages)"
        return
    fi
    local sep="----------------------------------------"
    local id role content raw_input thinking has_tc
    local ids
    ids=$(sqlite3 "$AI_AGENT_DB" "SELECT id FROM messages$where ORDER BY id" 2>/dev/null)
    for id in $ids; do
        role=$(sqlite3 "$AI_AGENT_DB" "SELECT role FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
        content=$(sqlite3 "$AI_AGENT_DB" "SELECT content FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
        raw_input=$(sqlite3 "$AI_AGENT_DB" "SELECT COALESCE(raw_input,'') FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
        thinking=$(sqlite3 "$AI_AGENT_DB" "SELECT COALESCE(thinking,'') FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
        has_tc=$(sqlite3 "$AI_AGENT_DB" "SELECT CASE WHEN EXISTS(SELECT 1 FROM tool_calls WHERE message_agent_id=$(db_quote "$agent") AND message_id=$id) THEN 1 ELSE 0 END" 2>/dev/null)
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
            tc_ids=$(sqlite3 "$AI_AGENT_DB" "SELECT id FROM tool_calls WHERE message_agent_id=$(db_quote "$agent") AND message_id=$id ORDER BY rowid" 2>/dev/null)
            for tc_id in $tc_ids; do
                tc_name=$(sqlite3 "$AI_AGENT_DB" "SELECT name FROM tool_calls WHERE agent_id=$(db_quote "$agent") AND id='$tc_id'" 2>/dev/null)
                tc_args=$(sqlite3 "$AI_AGENT_DB" "SELECT arguments FROM tool_calls WHERE agent_id=$(db_quote "$agent") AND id='$tc_id'" 2>/dev/null)
                tc_result=$(sqlite3 "$AI_AGENT_DB" "SELECT COALESCE(result,'') FROM tool_calls WHERE agent_id=$(db_quote "$agent") AND id='$tc_id'" 2>/dev/null)
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

# _hist_one <id> — single message + its tool calls.
_hist_one() {
    local id="$1"
    local agent
    agent=$(chat_table_id)
    local role content raw_input thinking
    role=$(sqlite3 "$AI_AGENT_DB" "SELECT role FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
    if [[ -z "$role" ]]; then
        warn "no message with id=$id in agent=$agent"
        return 1
    fi
    content=$(sqlite3 "$AI_AGENT_DB" "SELECT content FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
    raw_input=$(sqlite3 "$AI_AGENT_DB" "SELECT COALESCE(raw_input,'') FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
    thinking=$(sqlite3 "$AI_AGENT_DB" "SELECT COALESCE(thinking,'') FROM messages WHERE agent_id=$(db_quote "$agent") AND id=$id" 2>/dev/null)
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
    tc_ids=$(sqlite3 "$AI_AGENT_DB" "SELECT id FROM tool_calls WHERE message_agent_id=$(db_quote "$agent") AND message_id=$id ORDER BY rowid" 2>/dev/null)
    if [[ -n "$tc_ids" ]]; then
        for tc_id in $tc_ids; do
            tc_name=$(sqlite3 "$AI_AGENT_DB" "SELECT name FROM tool_calls WHERE agent_id=$(db_quote "$agent") AND id='$tc_id'" 2>/dev/null)
            tc_args=$(sqlite3 "$AI_AGENT_DB" "SELECT arguments FROM tool_calls WHERE agent_id=$(db_quote "$agent") AND id='$tc_id'" 2>/dev/null)
            tc_result=$(sqlite3 "$AI_AGENT_DB" "SELECT COALESCE(result,'') FROM tool_calls WHERE agent_id=$(db_quote "$agent") AND id='$tc_id'" 2>/dev/null)
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

# init_db — create ALL tables in $AI_AGENT_DB (idempotent). This used to be
# three separate init functions (init_db, init_blackboard, init_team_db);
# the new schema lives in one file so a single call covers everything.
init_db() {
    if [[ -f "$TEAM_SCHEMA" ]]; then
        sqlite3 "$AI_AGENT_DB" < "$TEAM_SCHEMA" || true
    fi
}

# sql / chat_sql / board_sql / task_sql — all aliases; the unified DB means
# there's only one connection path. Named aliases kept for readability at
# the call site.
sql() { sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" <<< "$1" || true; }
chat_sql() { sql "$@"; }
board_sql() { sql "$@"; }
task_sql() { sql "$@"; }

db_quote() {
    local q s
    q="''"
    s="${1//\'/$q}"
    printf "'%s'" "$s"
}
# Aliases for the unified-DB world.
chat_quote() { db_quote "$@"; }
board_quote() { db_quote "$@"; }

db_exec_returning() {
    # Insert an assistant message and echo the new per-agent id.
    local agent next_id
    agent=$(chat_table_id)
    next_id=$(next_chat_id)
    sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" \
        "INSERT INTO messages (agent_id, id, role, content) VALUES ($(db_quote "$agent"), $next_id, 'assistant', $(db_quote "$1"));" 2>/dev/null
    echo "$next_id"
}

# Back-compat shims. The old init functions are now no-ops because init_db
# already creates every table. Kept so any caller that still invokes them
# does not error.
init_blackboard() { :; }
init_team_db() { :; }
team_sql() { sql "$@"; }
bb_sql() { sql "$@"; }
bb_quote() { db_quote "$@"; }

add_message() {
    local role="$1" content="$2" raw="${3:-}" thinking="${4:-}"
    local agent next_id
    agent=$(chat_table_id)
    next_id=$(next_chat_id)
    local columns="(agent_id, id, role, content"
    local values="($(db_quote "$agent"), $next_id, $(db_quote "$role"), $(db_quote "$content")"
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
    local agent next_id mid
    agent=$(chat_table_id)
    mid=$(db_exec_returning "$content")
    if [[ -z "$mid" || "$mid" == "0" ]]; then
        warn "save_assistant_tool_call: failed to insert assistant message"
        return 1
    fi
    if [[ -n "$thinking" ]]; then
        sql "UPDATE messages SET thinking=$(db_quote "$thinking") WHERE agent_id=$(db_quote "$agent") AND id=$mid"
    fi

    local i=0 tc tcid name args
    while true; do
        tc=$(jq -c --argjson i "$i" '.[$i] // empty' <<< "$tc_array" 2>/dev/null) || break
        [[ -z "$tc" || "$tc" == "null" ]] && break
        tcid=$(jq -r '.id // ""' <<< "$tc")
        name=$(jq -r '.function.name // ""' <<< "$tc")
        args=$(jq -r '.function.arguments // "{}"' <<< "$tc")
        sql "INSERT INTO tool_calls (agent_id, id, message_agent_id, message_id, name, arguments) VALUES ($(db_quote "$agent"), $(db_quote "$tcid"), $(db_quote "$agent"), $mid, $(db_quote "$name"), $(db_quote "$args"))"
        i=$((i+1))
    done
}

save_tool_result() {
    local call_id="$1" result="$2"
    local agent
    agent=$(chat_table_id)
    sql "UPDATE tool_calls SET result=$(db_quote "$result") WHERE agent_id=$(db_quote "$agent") AND id=$(db_quote "$call_id")"
}

load_history() {
    local agent
    agent=$(chat_table_id)
    history_messages=$(sqlite3 "$AI_AGENT_DB" "
        SELECT json_group_array(json(payload)) FROM (
            WITH stream AS (
                SELECT m.id AS msg_id, 0 AS ord,
                       CASE
                           WHEN m.role IN ('system','user') THEN
                               json_object('role', m.role, 'content', COALESCE(m.content, ''))
                           WHEN m.role = 'assistant' AND EXISTS (
                               SELECT 1 FROM tool_calls tc2
                               WHERE tc2.message_agent_id = m.agent_id AND tc2.message_id = m.id
                           ) THEN
                               json_object(
                                   'role', 'assistant',
                                   'content', COALESCE(m.content, ''),
                                   'tool_calls', (
                                       SELECT json_group_array(json_object(
                                           'id', tc.id,
                                           'type', 'function',
                                           'function', json_object('name', tc.name, 'arguments', tc.arguments)
                                       ))
                                       FROM tool_calls tc
                                       WHERE tc.message_agent_id = m.agent_id AND tc.message_id = m.id
                                       ORDER BY tc.rowid
                                   )
                               )
                           WHEN m.role = 'assistant' THEN
                               json_object('role', 'assistant', 'content', COALESCE(m.content, ''))
                       END AS payload
                FROM messages m
                WHERE m.agent_id = '$(printf "%s" "$agent" | sed "s/'/''/g")'
                UNION ALL
                SELECT tc.message_id, tc.rowid,
                       json_object('role', 'tool', 'content', COALESCE(tc.result, ''), 'tool_call_id', tc.id)
                FROM tool_calls tc
                INNER JOIN messages m2
                    ON m2.agent_id = tc.message_agent_id AND m2.id = tc.message_id
                WHERE tc.agent_id = '$(printf "%s" "$agent" | sed "s/'/''/g")'
            )
            SELECT payload FROM stream ORDER BY msg_id, ord
        )
    " 2>/dev/null || echo "[]")
}

prune_history() {
    local agent count remove
    agent=$(chat_table_id)
    count=$(sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" \
        "SELECT COUNT(*) FROM messages WHERE agent_id=$(db_quote "$agent")" 2>/dev/null || echo 0)
    if (( count > MAX_HISTORY )); then
        remove=$((count - MAX_HISTORY))
        sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" \
            "DELETE FROM messages WHERE agent_id=$(db_quote "$agent") AND id IN (SELECT id FROM messages WHERE agent_id=$(db_quote "$agent") ORDER BY id LIMIT $remove)" || true
    fi
}
