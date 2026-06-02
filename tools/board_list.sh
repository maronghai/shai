#!/bin/sh
input="$1"
db="${BLACKBOARD_DB_PATH:-/data/blackboard.db}"

prefix=$(echo "$input" | jq -r '.prefix // ""' 2>/dev/null)

if [ -z "$prefix" ]; then
    sqlite3 "$db" "SELECT DISTINCT topic FROM board ORDER BY topic" -json 2>/dev/null
else
    esc_prefix=$(printf '%s' "$prefix" | sed "s/'/''/g")
    sqlite3 "$db" "SELECT DISTINCT topic FROM board WHERE topic LIKE '$esc_prefix%' ORDER BY topic" -json 2>/dev/null
fi
