#!/bin/bash
# Smoke test for the unified ai-agent DB.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
DB=/tmp/unified_smoke.db
rm -f "$DB"
export AI_AGENT_DB="$DB"

# 1. Seed schema
sqlite3 "$DB" < team/schema.sql
echo "=== 1. tables ==="
sqlite3 "$DB" '.tables'

# 2. Board write
echo
echo "=== 2. board write ==="
AGENT_NAME="alice" sh tools/board_write.sh '{"topic":"plan","payload":"step 1"}'

# 3. Task create
echo
echo "=== 3. task create ==="
AGENT_NAME="pm" sh tools/task_create.sh '{"title":"do X","description":"d","type":"code","priority":5}'

# 4. Cross-table query
echo
echo "=== 4. cross-table rows ==="
sqlite3 "$DB" "SELECT 'board' tbl,id,topic FROM board UNION ALL SELECT 'tasks' tbl,id,title FROM tasks;"

# 5. agent_id partition test: insert chat row, then check it's per-agent
echo
echo "=== 5. chat partition ==="
# Build a tiny script that emulates an add_message in agent=pm
sqlite3 "$DB" "INSERT INTO messages (agent_id, id, role, content) VALUES ('pm', 1, 'user', 'hello from pm');"
sqlite3 "$DB" "INSERT INTO messages (agent_id, id, role, content) VALUES ('default', 1, 'user', 'hello from default');"
sqlite3 "$DB" "INSERT INTO messages (agent_id, id, role, content) VALUES ('pm', 2, 'assistant', 'pm reply');"
sqlite3 "$DB" "SELECT agent_id, id, role, substr(content,1,30) FROM messages ORDER BY agent_id, id;"

# 6. FK cascade test: delete one of pm's messages; its tool_calls should also be deleted
echo
echo "=== 6. FK cascade ==="
sqlite3 "$DB" "INSERT INTO tool_calls (agent_id, id, message_agent_id, message_id, name, arguments) VALUES ('pm','tc1','pm',1,'read_file','{\"path\":\"/x\"}');"
sqlite3 "$DB" "SELECT 'before' tag, count(*) c FROM tool_calls WHERE agent_id='pm' AND message_id=1;"
sqlite3 "$DB" "DELETE FROM messages WHERE agent_id='pm' AND id=1;"
sqlite3 "$DB" "SELECT 'after' tag, count(*) c FROM tool_calls WHERE agent_id='pm' AND message_id=1;"

echo
echo "=== 7. file size ==="
ls -la "$DB"
