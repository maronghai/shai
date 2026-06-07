#!/bin/sh
# task_update.sh - update a task's status and/or append a progress note.
#
# Env:
#   AI_AGENT_DB    - path to the unified ai-agent.db
#   AGENT_NAME     - name of the calling agent (recorded in event log)

input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"
agent="${AGENT_NAME:-}"

task_id=$(printf "%s\n" "$input" | jq -r '.task_id // ""' 2>/dev/null)
new_status=$(printf "%s\n" "$input" | jq -r '.status // ""' 2>/dev/null)
message=$(printf "%s\n" "$input" | jq -r '.message // ""' 2>/dev/null)
event=$(printf "%s\n" "$input" | jq -r '.event // "comment"' 2>/dev/null)

if [ -z "$task_id" ]; then
    echo '{"success":false,"error":"missing task_id"}'
    exit 1
fi
if ! echo "$task_id" | grep -qE '^[0-9]+$'; then
    echo '{"success":false,"error":"task_id must be numeric"}'
    exit 1
fi

# Check task exists
exists=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE id=$task_id" 2>/dev/null)
if [ "$exists" != "1" ]; then
    echo "{\"success\":false,\"error\":\"task $task_id not found\"}"
    exit 1
fi

# Validate status if given
if [ -n "$new_status" ]; then
    case "$new_status" in
        pending|claimed|in_progress|review|done|blocked|cancelled) ;;
        *) echo '{"success":false,"error":"invalid status"}'; exit 1 ;;
    esac
    esc_agent=$(printf '%s' "$agent" | sed "s/'/''/g")
    sqlite3 "$db" "UPDATE tasks SET status='$new_status', updated_at=datetime('now') WHERE id=$task_id;" 2>/dev/null
    sqlite3 "$db" "INSERT INTO task_events (task_id, agent, event, message) VALUES ($task_id, '$esc_agent', '$new_status', 'status changed to $new_status');" 2>/dev/null
fi

# Append message as separate event
if [ -n "$message" ]; then
    esc_agent=$(printf '%s' "$agent" | sed "s/'/''/g")
    esc_message=$(printf '%s' "$message" | sed "s/'/''/g")
    sqlite3 "$db" "INSERT INTO task_events (task_id, agent, event, message) VALUES ($task_id, '$esc_agent', '$event', '$esc_message');" 2>/dev/null
fi

# Get current status
cur_status=$(sqlite3 "$db" "SELECT status FROM tasks WHERE id=$task_id" 2>/dev/null)
echo "{\"success\":true,\"task_id\":$task_id,\"status\":\"$cur_status\"}"
