#!/bin/sh
# task_show.sh - show one task + its event log as a single JSON object.
#
# Output: {"success":true,"task":{...},"events":[...]}
# All string fields are JSON-escaped; output is single-line parseable.

input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"

task_id=$(printf '%s\n' "$input" | jq -r '.task_id // ""' 2>/dev/null)
if [ -z "$task_id" ] || ! printf '%s' "$task_id" | grep -qE '^[0-9]+$'; then
    echo '{"success":false,"error":"missing or invalid task_id"}'
    exit 1
fi

# Exists?
exists=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE id=$task_id" 2>/dev/null | tr -d '\n')
if [ "$exists" != "1" ]; then
    echo "{\"success\":false,\"error\":\"task $task_id not found\"}"
    exit 1
fi

# Helper: fetch one field as plain text (preserves internal newlines, strips trailing)
field() {
    # Strip a single trailing newline if present, keep internal newlines
    sqlite3 "$db" "$1" 2>/dev/null | sed '$ { /^$/d }'
}

# Helper: JSON-encode a string (handles empty + internal newlines + quotes)
# Uses -Rsr (raw input, slurp, raw output) so the entire string is read AND output
# as a JSON string literal (with surrounding quotes and proper escaping).
json_str() {
    if [ -z "$1" ]; then
        echo '""'
    else
        printf '%s' "$1" | jq -Rsr 'if . == "" then "\"\"" else @json end'
    fi
}

# Fetch all task fields
id_v=$(field "SELECT id FROM tasks WHERE id=$task_id")
type_v=$(field "SELECT type FROM tasks WHERE id=$task_id")
status_v=$(field "SELECT status FROM tasks WHERE id=$task_id")
prio_v=$(field "SELECT priority FROM tasks WHERE id=$task_id")
title_v=$(field "SELECT title FROM tasks WHERE id=$task_id")
desc_v=$(field "SELECT COALESCE(description,'') FROM tasks WHERE id=$task_id")
asg_v=$(field "SELECT COALESCE(assigned_to,'') FROM tasks WHERE id=$task_id")
deps_v=$(field "SELECT COALESCE(depends_on,'') FROM tasks WHERE id=$task_id")
result_v=$(field "SELECT COALESCE(result,'') FROM tasks WHERE id=$task_id")
art_v=$(field "SELECT COALESCE(artifacts,'') FROM tasks WHERE id=$task_id")
created_v=$(field "SELECT created_at FROM tasks WHERE id=$task_id")
updated_v=$(field "SELECT updated_at FROM tasks WHERE id=$task_id")

# Build events array
events_j="["
first=1
ev_ids=$(sqlite3 "$db" "SELECT id FROM task_events WHERE task_id=$task_id ORDER BY id ASC" 2>/dev/null)
for ev_id in $ev_ids; do
    [ -z "$ev_id" ] && continue
    ev_agent=$(field "SELECT COALESCE(agent,'') FROM task_events WHERE id=$ev_id")
    ev_event=$(field "SELECT event FROM task_events WHERE id=$ev_id")
    ev_msg=$(field "SELECT COALESCE(message,'') FROM task_events WHERE id=$ev_id")
    ev_created=$(field "SELECT created_at FROM task_events WHERE id=$ev_id")
    [ $first -eq 0 ] && events_j="$events_j,"
    events_j="$events_j{\"id\":$ev_id,\"agent\":$(json_str "$ev_agent"),\"event\":$(json_str "$ev_event"),\"message\":$(json_str "$ev_msg"),\"created_at\":$(json_str "$ev_created")}"
    first=0
done
events_j="$events_j]"

# Compose
cat <<EOF
{"success":true,"task":{"id":$id_v,"title":$(json_str "$title_v"),"description":$(json_str "$desc_v"),"type":$(json_str "$type_v"),"status":$(json_str "$status_v"),"assigned_to":$(json_str "$asg_v"),"depends_on":$(json_str "$deps_v"),"priority":$prio_v,"result":$(json_str "$result_v"),"artifacts":$(json_str "$art_v"),"created_at":$(json_str "$created_v"),"updated_at":$(json_str "$updated_v")},"events":$events_j}
EOF
