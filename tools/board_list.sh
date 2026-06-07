#!/bin/sh
input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"

prefix=$(printf "%s\n" "$input" | jq -r '.prefix // ""' 2>/dev/null)

if [ -z "$prefix" ]; then
    sqlite3 "$db" "SELECT DISTINCT topic FROM board ORDER BY topic" -json 2>/dev/null
else
    esc_prefix=$(printf '%s' "$prefix" | sed "s/'/''/g")
    sqlite3 "$db" "SELECT DISTINCT topic FROM board WHERE topic LIKE '$esc_prefix%' ORDER BY topic" -json 2>/dev/null
fi
