#!/bin/sh
# task_done.sh - mark a task as done and record the result.
#
# Env:
#   AI_AGENT_DB    - path to the unified ai-agent.db
#   AGENT_NAME     - name of the calling agent

input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"
agent="${AGENT_NAME:-}"

task_id=$(printf "%s\n" "$input" | jq -r '.task_id // ""' 2>/dev/null)
result=$(printf "%s\n" "$input" | jq -r '.result // ""' 2>/dev/null)
artifacts=$(printf "%s\n" "$input" | jq -r '.artifacts // ""' 2>/dev/null)

if [ -z "$task_id" ]; then
    echo '{"success":false,"error":"missing task_id"}'
    exit 1
fi
if [ -z "$result" ]; then
    echo '{"success":false,"error":"missing result"}'
    exit 1
fi
if ! echo "$task_id" | grep -qE '^[0-9]+$'; then
    echo '{"success":false,"error":"task_id must be numeric"}'
    exit 1
fi

# Check task exists and is in a state that can transition to done
cur=$(sqlite3 -separator '|' "$db" "SELECT status, COALESCE(assigned_to,'') FROM tasks WHERE id=$task_id" 2>/dev/null)
if [ -z "$cur" ]; then
    echo "{\"success\":false,\"error\":\"task $task_id not found\"}"
    exit 1
fi
cur_status=$(echo "$cur" | cut -d'|' -f1)
cur_asg=$(echo "$cur" | cut -d'|' -f2)

# Only the claimer or coordinator can mark done
if [ -n "$cur_asg" ] && [ "$cur_asg" != "$agent" ] && [ "$agent" != "coordinator" ]; then
    echo "{\"success\":false,\"error\":\"task $task_id is claimed by '$cur_asg', not '$agent'\"}"
    exit 1
fi

# Truncate large results
if [ "${#result}" -gt 50000 ]; then
    result="${result}... [truncated]"
fi
if [ "${#artifacts}" -gt 10000 ]; then
    artifacts=""
fi

esc_result=$(printf '%s' "$result" | sed "s/'/''/g")
esc_artifacts=$(printf '%s' "$artifacts" | sed "s/'/''/g")
esc_agent=$(printf '%s' "$agent" | sed "s/'/''/g")

sqlite3 "$db" "UPDATE tasks SET status='done', result='$esc_result', artifacts='$esc_artifacts', updated_at=datetime('now') WHERE id=$task_id;" 2>/dev/null
sqlite3 "$db" "INSERT INTO task_events (task_id, agent, event, message) VALUES ($task_id, '$esc_agent', 'done', 'marked done by $agent');" 2>/dev/null

echo "{\"success\":true,\"task_id\":$task_id,\"status\":\"done\"}"
