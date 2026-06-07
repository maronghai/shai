#!/bin/sh
# board_clear — clear blackboard entries by topic
#   Two modes — same shape as task_clear.sh:
#     - soft (default):  rename topic "[cleared] <topic>" (audit-preserving;
#                        entries remain queryable by id, payload intact)
#     - hard ({"yes":true}): DELETE all rows with that topic from the board
#     - In both modes, an UNRELATED soft-cleared prefix "[cleared] ..." is
#       left alone (soft is idempotent).
#   Idempotent: returns success even when there's nothing to clear.
input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"

yes=$(printf "%s\n" "$input" | jq -r '.yes // false' 2>/dev/null)
topic=$(printf "%s\n" "$input" | jq -r '.topic // ""' 2>/dev/null)

if [ -z "$topic" ]; then
    echo '{"success":false,"error":"missing topic"}'
    exit 1
fi

# SQL escape: ' -> ''
esc_topic=$(printf '%s' "$topic" | sed "s/'/''/g")

# Count current rows for this topic (so the caller can show the impact)
n=$(sqlite3 "$db" "SELECT COUNT(*) FROM board WHERE topic = '$esc_topic'" 2>/dev/null)
n=${n:-0}

if [ "$yes" = "true" ]; then
    # Hard mode: actually DELETE the rows. There is no audit log on the
    # blackboard (it's free-form), so this is the same as "remove this topic".
    sqlite3 "$db" "DELETE FROM board WHERE topic = '$esc_topic'" 2>/dev/null
    printf '{"success":true,"mode":"hard","topic":"%s","deleted":%s}\n' \
        "$topic" "$n"
else
    # Soft mode: rename topic to "[cleared] <topic>". Idempotent — if the
    # topic is already in [cleared] form, do nothing.
    if printf '%s' "$topic" | grep -qF '[cleared] '; then
        # Already cleared: just count and report
        printf '{"success":true,"mode":"soft","topic":"%s","deleted":%s,"note":"already cleared"}\n' \
            "$topic" "$n"
    else
        new_topic="[cleared] $topic"
        esc_new=$(printf '%s' "$new_topic" | sed "s/'/''/g")
        sqlite3 "$db" "UPDATE board SET topic = '$esc_new' WHERE topic = '$esc_topic'" 2>/dev/null
        printf '{"success":true,"mode":"soft","topic":"%s","renamed_to":"%s","affected":%s}\n' \
            "$topic" "$new_topic" "$n"
    fi
fi
