#!/bin/sh
# task_list.sh - query the team queue.
#
# Optional filters (read from JSON arg $1):
#   status      - pending|claimed|in_progress|review|done|blocked|cancelled
#   type        - spec|design|code|review|test|docs|meta
#   assigned_to - exact agent name
#   ready       - if "1", only pending tasks whose depends_on are all done
#
# Env:
#   TEAM_DB_PATH   - path to team.db

input="$1"
db="${TEAM_DB_PATH:-/data/team.db}"

status=$(printf "%s\n" "$input" | jq -r '.status // ""' 2>/dev/null)
type=$(printf "%s\n" "$input" | jq -r '.type // ""' 2>/dev/null)
assigned_to=$(printf "%s\n" "$input" | jq -r '.assigned_to // ""' 2>/dev/null)
ready=$(printf "%s\n" "$input" | jq -r '.ready // 0' 2>/dev/null)
limit=$(printf "%s\n" "$input" | jq -r '.limit // 0' 2>/dev/null)

where=""
[ -n "$status" ]      && where="$where AND status='$status'"
[ -n "$type" ]        && where="$where AND type='$type'"
[ -n "$assigned_to" ] && where="$where AND assigned_to='$assigned_to'"

limit_clause=""
[ "$limit" -gt 0 ] 2>/dev/null && limit_clause=" LIMIT $limit"

if [ "$ready" = "1" ]; then
    # Pending tasks whose depends_on (comma-separated ids) are all 'done'
    base="SELECT id, type, status, COALESCE(assigned_to,''), title, COALESCE(depends_on,''), priority, created_at FROM tasks WHERE status='pending'$where AND (COALESCE(depends_on,'') = '' OR NOT EXISTS (SELECT 1 FROM tasks d WHERE (',' || tasks.depends_on || ',') LIKE ('%,' || d.id || ',%') AND d.status != 'done')) ORDER BY priority DESC, id ASC$limit_clause"
else
    base="SELECT id, type, status, COALESCE(assigned_to,''), title, COALESCE(depends_on,''), priority, created_at FROM tasks WHERE 1=1$where ORDER BY priority DESC, id ASC$limit_clause"
fi

rows=$(sqlite3 -separator '|' "$db" "$base" 2>/dev/null)
if [ -z "$rows" ]; then
    echo '[]'
    exit 0
fi

# Build JSON array with awk (keeps first/separator logic in one process)
printf '%s\n' "$rows" | awk '
BEGIN { FS = "|"; first=1; printf "[" }
{
    # JSON-escape title and assigned_to: backslash, double-quote
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
}
{
    if (first == 0) printf ","
    printf "{\"id\":%s,\"type\":\"%s\",\"status\":\"%s\",\"assigned_to\":\"%s\",\"title\":\"%s\",\"depends_on\":\"%s\",\"priority\":%s,\"created_at\":\"%s\"}",
        $1, $2, $3, $4, $5, $6, $7, $8
    first=0
}
END { printf "]\n" }
'
