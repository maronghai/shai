#!/bin/sh
# task_claim.sh - claim a pending task for the calling agent.
#
# Refuses if:
#   - task does not exist
#   - task is already claimed/in_progress/done by another agent
#   - any task in depends_on is not 'done'
#
# Env:
#   AI_AGENT_DB    - path to the unified ai-agent.db
#   AGENT_NAME     - name of the calling agent (becomes assigned_to)

input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"
agent="${AGENT_NAME:-}"

task_id=$(printf "%s\n" "$input" | jq -r '.task_id // ""' 2>/dev/null)
if [ -z "$task_id" ]; then
    echo '{"success":false,"error":"missing task_id"}'
    exit 1
fi
if ! echo "$task_id" | grep -qE '^[0-9]+$'; then
    echo '{"success":false,"error":"task_id must be a positive integer"}'
    exit 1
fi
if [ -z "$agent" ]; then
    echo '{"success":false,"error":"no AGENT_NAME in env (cannot claim anonymously)"}'
    exit 1
fi

esc_agent=$(printf '%s' "$agent" | sed "s/'/''/g")

# Check task exists
row=$(sqlite3 -separator '|' "$db" "SELECT status, COALESCE(assigned_to,''), COALESCE(depends_on,'') FROM tasks WHERE id=$task_id" 2>/dev/null)
if [ -z "$row" ]; then
    echo "{\"success\":false,\"error\":\"task $task_id not found\"}"
    exit 1
fi
status=$(echo "$row" | cut -d'|' -f1)
asg=$(echo "$row" | cut -d'|' -f2)
deps=$(echo "$row" | cut -d'|' -f3)

# Allow re-claim by the same agent (resume work) OR first-time claim
if [ -n "$asg" ] && [ "$asg" != "$agent" ] && [ "$status" != "pending" ]; then
    echo "{\"success\":false,\"error\":\"task $task_id already $status by '$asg'\"}"
    exit 1
fi

# Check dependencies all done
if [ -n "$deps" ]; then
    not_done=$(echo "$deps" | tr ',' '\n' | while read -r d; do
        [ -z "$d" ] && continue
        s=$(sqlite3 "$db" "SELECT status FROM tasks WHERE id=$d" 2>/dev/null)
        if [ "$s" != "done" ]; then echo "$d:$s"; fi
    done | tr '\n' ',')
    if [ -n "$not_done" ]; then
        echo "{\"success\":false,\"error\":\"deps not done: $not_done\"}"
        exit 1
    fi
fi

# Claim it
sqlite3 "$db" "UPDATE tasks SET status='claimed', assigned_to='$esc_agent', updated_at=datetime('now') WHERE id=$task_id;" 2>/dev/null
sqlite3 "$db" "INSERT INTO task_events (task_id, agent, event, message) VALUES ($task_id, '$esc_agent', 'claimed', 'task claimed by $agent');" 2>/dev/null

echo "{\"success\":true,\"task_id\":$task_id,\"assigned_to\":\"$agent\",\"status\":\"claimed\"}"
