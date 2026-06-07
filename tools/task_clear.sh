#!/bin/sh
# task_clear.sh - clear the task queue.
#
# Two modes:
#   soft (default, "yes"=false/missing): flip pending|claimed|in_progress|review|blocked
#                   to 'cancelled'. done/cancelled tasks are preserved. Rows stay,
#                   task_events audit trail stays. Idempotent and safe. Use this for
#                   a "do over" while keeping history.
#
#   hard ("yes"=true): DELETE EVERY task row + ALL its task_events rows.
#                   This is a full wipe of the `tasks` table — done, cancelled,
#                   pending, everything. The audit trail is GONE for all tasks.
#                   Cannot be undone from inside the script.
#
# In both modes, team_state (current_goal / current_goal_id) is NOT modified.
# Use /team clear if you also want the goal cleared.
# For a true wipe of EVERYTHING in the unified DB (incl. team_state, board, all chat), use rm -f .data/ai-agent.db.
#
# Output: {"success":true,"mode":"soft|hard",
#           "deleted":N,  (soft: tasks flipped; hard: tasks removed)
#           "events_deleted":M,  (hard mode only — 0 in soft)
#           "preserved_done":X,"preserved_cancelled":Y,  (soft only)
#           "total_after":Z}
#
# Env:
#   AI_AGENT_DB    - path to the unified ai-agent.db

input="$1"
db="${AI_AGENT_DB:-/data/ai-agent.db}"

# Parse input — does the caller want hard delete?
hard=0
if [ -n "$input" ]; then
    yes=$(printf "%s\n" "$input" | jq -r '.yes // false' 2>/dev/null)
    case "$yes" in
        true|1|yes) hard=1 ;;
    esac
fi

if [ "$hard" = "1" ]; then
    # HARD mode: delete every task row + every task_event row.
    # This is the "really wipe the task queue" semantic — done and cancelled
    # tasks are also removed. Audit trail is GONE.
    t_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks" 2>/dev/null)
    ev_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM task_events" 2>/dev/null)
    if [ "${t_before:-0}" -eq 0 ] && [ "${ev_before:-0}" -eq 0 ]; then
        cat <<EOF
{"success":true,"mode":"hard","deleted":0,"events_deleted":0,"total_after":0}
EOF
        exit 0
    fi
    # ON DELETE CASCADE on task_events.task_id would handle events when we delete
    # tasks, but be explicit + enable FK pragma so it's safe if schema changes.
    sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$db" "DELETE FROM task_events; DELETE FROM tasks; DELETE FROM sqlite_sequence;" 2>/dev/null
    cat <<EOF
{"success":true,"mode":"hard","deleted":${t_before:-0},"events_deleted":${ev_before:-0},"total_after":0}
EOF
else
    # SOFT mode: flip non-done → cancelled. Rows + audit preserved.
    t_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks" 2>/dev/null)
    c_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE status IN ('pending','claimed','in_progress','review','blocked')" 2>/dev/null)
    done_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE status='done'" 2>/dev/null)
    canc_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE status='cancelled'" 2>/dev/null)
    if [ "${c_count:-0}" -eq 0 ]; then
        cat <<EOF
{"success":true,"mode":"soft","deleted":0,"events_deleted":0,"preserved_done":${done_count:-0},"preserved_cancelled":${canc_count:-0},"total_after":${t_count:-0}}
EOF
        exit 0
    fi
    sqlite3 "$db" "UPDATE tasks SET status='cancelled', updated_at=datetime('now') WHERE status IN ('pending','claimed','in_progress','review','blocked');" 2>/dev/null
    final_total=$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks" 2>/dev/null)
    cat <<EOF
{"success":true,"mode":"soft","deleted":${c_count:-0},"events_deleted":0,"preserved_done":${done_count:-0},"preserved_cancelled":${canc_count:-0},"total_after":${final_total:-0}}
EOF
fi
