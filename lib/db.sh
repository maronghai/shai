# lib/db.sh — Database primitives for ai-agent.sh
#
# Sourced by ai-agent.sh. Provides:
#   - DB_PATH resolution (db_path, load_system_prompt)
#   - SQLite init (init_db, init_blackboard, init_team_db)
#   - Query helpers (sql, team_sql, bb_sql, db_quote, db_exec_returning, bb_quote)
#   - Message persistence (add_message, save_assistant_tool_call, save_tool_result)
#   - History (load_history, prune_history)
#   - /hist dumpers (_hist_full, _hist_one)
#
# Variables read at call time (must be set by caller before any function is called):
#   $WORK_DIR, $DATA_DIR, $AGENTS_DIR, $CURRENT_AGENT, $DB_PATH, $BLACKBOARD_DB,
#   $TEAM_DB, $TEAM_SCHEMA

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

init_team_db() {
    if [[ -f "$TEAM_SCHEMA" ]]; then
        sqlite3 "$TEAM_DB" < "$TEAM_SCHEMA" || true
    else
        # Fallback: inline schema (matches team/schema.sql)
        sqlite3 "$TEAM_DB" <<'SQL' || true
            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                description TEXT,
                type TEXT NOT NULL CHECK (type IN ('spec','design','code','review','test','docs','meta')),
                status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','claimed','in_progress','review','done','blocked','cancelled')),
                assigned_to TEXT,
                depends_on TEXT,
                priority INTEGER DEFAULT 0,
                result TEXT,
                artifacts TEXT,
                created_at TEXT DEFAULT (datetime('now')),
                updated_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
            CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(type);
            CREATE INDEX IF NOT EXISTS idx_tasks_assigned ON tasks(assigned_to);
            CREATE TABLE IF NOT EXISTS task_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER NOT NULL,
                agent TEXT,
                event TEXT NOT NULL,
                message TEXT,
                created_at TEXT DEFAULT (datetime('now')),
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_events_task ON task_events(task_id);
            CREATE TABLE IF NOT EXISTS team_state (
                key   TEXT PRIMARY KEY,
                value TEXT,
                updated_at TEXT DEFAULT (datetime('now'))
            );
SQL
    fi
}
team_sql() { sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$TEAM_DB" <<< "$1" || true; }
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
