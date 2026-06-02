#!/bin/sh
input="$1"
db="${BLACKBOARD_DB_PATH:-/data/blackboard.db}"
agent="${AGENT_NAME:-}"

topic=$(echo "$input" | jq -r '.topic // ""' 2>/dev/null)
payload=$(echo "$input" | jq -r '.payload // ""' 2>/dev/null)
reply_to=$(echo "$input" | jq -r '.reply_to // null' 2>/dev/null)

if [ -z "$topic" ]; then
    echo '{"success":false,"error":"missing topic"}'
    exit 1
fi
if [ -z "$payload" ]; then
    echo '{"success":false,"error":"missing payload"}'
    exit 1
fi

# Truncate very large payloads (SQLite has no limit but bounded size keeps DB clean)
pllen=$(printf '%s' "$payload" | wc -c)
if [ "$pllen" -gt 100000 ]; then
    payload=$(printf '%s' "$payload" | head -c 100000)
    payload="${payload}
... [truncated, $pllen total chars]"
fi

# SQL single-quote escape: ' -> ''
esc_topic=$(printf '%s' "$topic" | sed "s/'/''/g")
esc_payload=$(printf '%s' "$payload" | sed "s/'/''/g")
esc_agent=$(printf '%s' "$agent" | sed "s/'/''/g")

if [ "$reply_to" = "null" ] || [ -z "$reply_to" ]; then
    sql="INSERT INTO board (agent, topic, payload) VALUES ('$esc_agent', '$esc_topic', '$esc_payload'); SELECT last_insert_rowid();"
else
    sql="INSERT INTO board (agent, topic, payload, reply_to) VALUES ('$esc_agent', '$esc_topic', '$esc_payload', $reply_to); SELECT last_insert_rowid();"
fi

new_id=$(sqlite3 "$db" "$sql" 2>/dev/null | tail -1)
if [ -z "$new_id" ] || [ "$new_id" = "0" ]; then
    echo '{"success":false,"error":"insert failed"}'
    exit 1
fi
echo "{\"id\":$new_id,\"agent\":\"$esc_agent\",\"topic\":\"$esc_topic\"}"
