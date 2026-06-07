#!/bin/sh
# task_create.sh - create a new task in the team queue.
#
# Env:
#   AI_AGENT_DB    - path to the unified ai-agent.db (default: /data/ai-agent.db)
#   AGENT_NAME     - name of the calling agent (recorded in event log)
#
# Reads JSON from $1, returns JSON.

input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"
agent="${AGENT_NAME:-}"

title=$(printf "%s\n" "$input" | jq -r '.title // ""' 2>/dev/null)
description=$(printf "%s\n" "$input" | jq -r '.description // ""' 2>/dev/null)
type=$(printf "%s\n" "$input" | jq -r '.type // ""' 2>/dev/null)
depends_on=$(printf "%s\n" "$input" | jq -r '.depends_on // ""' 2>/dev/null)
priority=$(printf "%s\n" "$input" | jq -r '.priority // 0' 2>/dev/null)

if [ -z "$title" ]; then
    echo '{"success":false,"error":"missing title"}'
    exit 1
fi
if [ -z "$type" ]; then
    echo '{"success":false,"error":"missing type"}'
    exit 1
fi
case "$type" in
    spec|design|code|review|test|docs|meta) ;;
    *) echo '{"success":false,"error":"invalid type (must be spec|design|code|review|test|docs|meta)"}'; exit 1 ;;
esac

# Truncate very large descriptions
if [ "${#description}" -gt 50000 ]; then
    description="${description}... [truncated]"
fi

# SQL escape: ' -> ''
esc_title=$(printf '%s' "$title" | sed "s/'/''/g")
esc_description=$(printf '%s' "$description" | sed "s/'/''/g")
esc_depends=$(printf '%s' "$depends_on" | sed "s/'/''/g")
esc_agent=$(printf '%s' "$agent" | sed "s/'/''/g")

sql="INSERT INTO tasks (title, description, type, depends_on, priority) VALUES (
    '$esc_title',
    '$esc_description',
    '$type',
    '$esc_depends',
    $priority
);
SELECT last_insert_rowid();"

new_id=$(sqlite3 "$db" "$sql" 2>/dev/null | tail -1)
if [ -z "$new_id" ] || [ "$new_id" = "0" ]; then
    echo '{"success":false,"error":"insert failed"}'
    exit 1
fi

# Record the creation event
ev_sql="INSERT INTO task_events (task_id, agent, event, message) VALUES ($new_id, '$esc_agent', 'created', 'task created');"
sqlite3 "$db" "$ev_sql" 2>/dev/null

title_j=$(printf '%s' "$title" | jq -Rsr 'if . == "" then "\"\"" else @json end')
jq -nc --argjson id "$new_id" --argjson title "$title_j" --arg type "$type" '{id:$id, title:$title, type:$type, status:"pending"}'
