#!/bin/sh
input="$1"
db="${BLACKBOARD_DB_PATH:-/data/blackboard.db}"

topic=$(printf "%s\n" "$input" | jq -r '.topic // ""' 2>/dev/null)
since=$(printf "%s\n" "$input" | jq -r '.since_id // 0' 2>/dev/null)
limit=$(printf "%s\n" "$input" | jq -r '.limit // 50' 2>/dev/null)

if [ -z "$topic" ]; then
    echo '{"success":false,"error":"missing topic"}'
    exit 1
fi

# Bound limit
if [ -z "$limit" ] || [ "$limit" -lt 1 ]; then limit=50; fi
if [ "$limit" -gt 500 ]; then limit=500; fi
if [ -z "$since" ]; then since=0; fi

esc_topic=$(printf '%s' "$topic" | sed "s/'/''/g")
sqlite3 "$db" "SELECT id, agent, topic, payload, COALESCE(reply_to, 0) AS reply_to, created_at FROM board WHERE topic = '$esc_topic' AND id > $since ORDER BY id LIMIT $limit" -json 2>/dev/null
