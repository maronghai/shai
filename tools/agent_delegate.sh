#!/bin/sh
# agent_delegate.sh - Spawn a sub-agent, wait for its reply, return it.
#
# Env (set by main script's run_tool):
#   AGENT_NAME          - name of the calling agent
#   DELEGATION_DEPTH    - integer; we increment by 1
#   BLACKBOARD_DB_PATH  - path to blackboard.db
#   WORK_DIR, AGENTS_DIR - main script's paths
#
# Args (from LLM function call):
#   {agent, task, topic?}

input="$1"
db="${BLACKBOARD_DB_PATH:-/data/blackboard.db}"
work_dir="${WORK_DIR:-/data}"
agents_dir="${AGENTS_DIR:-/data/agents}"
from_agent="${AGENT_NAME:-}"
depth="${DELEGATION_DEPTH:-0}"

agent=$(printf "%s\n" "$input" | jq -r '.agent // ""' 2>/dev/null)
task=$(printf "%s\n" "$input" | jq -r '.task // ""' 2>/dev/null)
topic=$(printf "%s\n" "$input" | jq -r '.topic // ""' 2>/dev/null)

# Validate agent name
if [ -z "$agent" ] || [ "$agent" = "null" ]; then
    echo '{"success":false,"error":"missing agent"}'
    exit 1
fi
case "$agent" in
    *[!a-zA-Z0-9_-]*)
        echo '{"success":false,"error":"invalid agent name"}'
        exit 1
        ;;
esac
if [ ! -f "$agents_dir/$agent/system.md" ]; then
    echo "{\"success\":false,\"error\":\"agent '$agent' not found (missing $agents_dir/$agent/system.md)\"}"
    exit 1
fi
if [ -z "$task" ] || [ "$task" = "null" ]; then
    echo '{"success":false,"error":"missing task"}'
    exit 1
fi

# Auto-generate topic if not provided
if [ -z "$topic" ] || [ "$topic" = "null" ]; then
    topic="delegate-$(date +%s)-$$"
fi

# Hard limit on recursion
if [ "$depth" -ge 2 ]; then
    echo '{"success":false,"error":"max delegation depth reached"}'
    exit 1
fi

# Truncate very large task
tlen=$(printf '%s' "$task" | wc -c)
if [ "$tlen" -gt 8000 ]; then
    task_trunc=$(printf '%s' "$task" | head -c 8000)
    task="${task_trunc}
... [truncated, $tlen total chars]"
fi

# SQL single-quote escape
esc_topic=$(printf '%s' "$topic" | sed "s/'/''/g")
esc_task=$(printf '%s' "$task" | sed "s/'/''/g")
esc_from=$(printf '%s' "$from_agent" | sed "s/'/''/g")

# Write task to blackboard; capture parent_id
parent_id=$(sqlite3 "$db" "INSERT INTO board (agent, topic, payload) VALUES ('$esc_from', '$esc_topic', '$esc_task'); SELECT last_insert_rowid();" 2>/dev/null | tail -1)
if [ -z "$parent_id" ] || [ "$parent_id" = "0" ]; then
    echo '{"success":false,"error":"failed to write task to blackboard"}'
    exit 1
fi

# Find main script (parent of tools/)
tools_dir="$(cd "$(dirname "$0")" && pwd)"
main_script="$(dirname "$tools_dir")/ai-agent.sh"
if [ ! -f "$main_script" ]; then
    echo "{\"success\":false,\"error\":\"main script not found at $main_script\",\"parent_id\":$parent_id}"
    exit 1
fi

# Spawn child in background
NON_INTERACTIVE=1 \
    AGENT_NAME="$agent" \
    DELEGATION_DEPTH=$((depth + 1)) \
    PARENT_ID="$parent_id" \
    TASK="$task" \
    TOPIC="$topic" \
    BLACKBOARD_DB_PATH="$db" \
    TEAM_DB_PATH="${TEAM_DB_PATH:-}" \
    bash "$main_script" >/dev/null 2>&1 &
child_pid=$!

# Wait up to 300 seconds (long for PM planning)
deadline=$(( $(date +%s) + 300 ))
while kill -0 "$child_pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        kill -TERM "$child_pid" 2>/dev/null
        sleep 1
        kill -KILL "$child_pid" 2>/dev/null
        echo "{\"success\":false,\"error\":\"agent '$agent' timed out after 300s\",\"parent_id\":$parent_id}"
        exit 1
    fi
    sleep 1
done

# Wait briefly for the reply to land in blackboard
deadline=$(( $(date +%s) + 5 ))
reply=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    reply=$(sqlite3 "$db" "SELECT payload FROM board WHERE reply_to = $parent_id ORDER BY id DESC LIMIT 1" 2>/dev/null)
    if [ -n "$reply" ]; then break; fi
    sleep 1
done

if [ -z "$reply" ]; then
    echo "{\"success\":false,\"error\":\"agent '$agent' finished without writing reply\",\"parent_id\":$parent_id}"
    exit 1
fi

# Truncate reply for the caller
rlen=$(printf '%s' "$reply" | wc -c)
if [ "$rlen" -gt 8000 ]; then
    reply_trunc=$(printf '%s' "$reply" | head -c 8000)
    reply="${reply_trunc}
... [truncated, $rlen total chars]"
fi
echo "$reply"
