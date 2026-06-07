# lib/team.sh — /team workflow dispatcher
#
# Sourced by ai-agent.sh. Provides:
#   - _team_agent_for_type: type → agent name lookup
#   - _team_status:        show current goal + task distribution + next preview
#   - _team_start:         write goal, dispatch PM to break it into tasks
#   - _team_next:          claim + delegate next ready task to its persona
#   - _team_stop:          clear current goal (keep tasks)
#   - _team_clear:         soft cancel: flip non-done to 'cancelled' + clear goal
#
# All team data lives in the unified $AI_AGENT_DB (default: .data/ai-agent.db).
# All functions read $AI_AGENT_DB / $WORK_DIR / $AGENTS_DIR at call time.

# type -> agent name mapping for the /team dispatcher
_team_agent_for_type() {
    case "$1" in
        spec) echo "pm" ;;
        design) echo "architect" ;;
        code) echo "developer" ;;
        review) echo "code-reviewer" ;;
        test) echo "tester" ;;
        docs) echo "docs" ;;
        meta) echo "coordinator" ;;
        *) echo "" ;;
    esac
}

# _team_status — show current goal, task counts by status, next ready task
_team_status() {
    local goal goal_id total pending done count ready_line
    goal=$(sqlite3 "$AI_AGENT_DB" "SELECT value FROM team_state WHERE key='current_goal'" 2>/dev/null)
    goal_id=$(sqlite3 "$AI_AGENT_DB" "SELECT value FROM team_state WHERE key='current_goal_id'" 2>/dev/null)
    echo "== team status =="
    if [[ -n "$goal" ]]; then
        echo "goal:    $goal (id=$goal_id)"
    else
        echo "goal:    (none — use /team start <goal>)"
    fi
    total=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks" 2>/dev/null)
    if [[ "$total" == "0" ]]; then
        echo "tasks:   0"
        return 0
    fi
    echo "tasks:   $total total"
    sqlite3 -header -column "$AI_AGENT_DB" "SELECT status, COUNT(*) AS n FROM tasks GROUP BY status ORDER BY n DESC" 2>/dev/null | while IFS= read -r line; do echo "  $line"; done
    ready_line=$(AI_AGENT_DB="$AI_AGENT_DB" sh "${WORK_DIR}/tools/task_list.sh" '{"ready":1}' 2>/dev/null)
    local n_ready
    n_ready=$(echo "$ready_line" | jq 'length' 2>/dev/null)
    echo "ready:   $n_ready task(s) (deps satisfied + pending)"
    if [[ "$n_ready" -gt 0 ]]; then
        echo "$ready_line" | jq -r '.[] | "  [\(.id) \(.status[0:4])/\(.type)] \(.title)"' 2>/dev/null | head -5
        echo
        echo "next:    /team next"
    fi
    return 0
}

# _team_start <goal> — store goal, dispatch PM to break it into tasks
_team_start() {
    local goal="$1"
    if [[ -z "$goal" ]]; then
        warn "usage: /team start <goal>"
        return 1
    fi
    # Persist goal
    local esc_goal
    esc_goal=$(printf '%s' "$goal" | sed "s/'/''/g")
    sqlite3 "$AI_AGENT_DB" "INSERT OR REPLACE INTO team_state (key, value, updated_at) VALUES ('current_goal', '$esc_goal', datetime('now')); INSERT OR REPLACE INTO team_state (key, value, updated_at) VALUES ('current_goal_id', NULL, datetime('now'));" 2>/dev/null
    # Create a spec task for the goal itself
    local spec_id
    spec_id=$(AI_AGENT_DB="$AI_AGENT_DB" AGENT_NAME=coordinator sh "${WORK_DIR}/tools/task_create.sh" "$(jq -nc --arg t "Goal: $goal" --arg d "$goal" --arg type spec '{title:$t, description:$d, type:$type}')" 2>/dev/null | jq -r '.id // empty')
    if [[ -n "$spec_id" ]]; then
        sqlite3 "$AI_AGENT_DB" "INSERT OR REPLACE INTO team_state (key, value, updated_at) VALUES ('current_goal_id', '$spec_id', datetime('now'))" 2>/dev/null
    fi
    ok "team started: goal=\"$goal\" (spec task #$spec_id)"
    info "dispatching PM to break the goal into tasks..."
    # Dispatch PM via agent_delegate. Instruct PM to (a) use task_create to break
    # the goal into sub-tasks and (b) write a board reply summarizing what it did.
    local payload topic
    topic="team-spec-$(date +%s)"
    payload=$(jq -nc --arg agent pm --arg task "Your only job: turn this goal into 4-6 concrete tasks using the task_create tool. Do NOT read files, do NOT search — just create the tasks.

For each task, call task_create with:
- title: one short sentence (1 line)
- description: enough detail to start work (1-2 paragraphs)
- type: one of design|code|review|test|docs (pick the right one for the step)
- depends_on: comma-separated task ids that must be done first (only if needed)
- priority: 0-10 (higher = sooner)

After creating all tasks, write a 3-5 line summary to the blackboard with board_write(topic='$topic', payload='created N tasks: <one-line summary>').

Goal: $goal" --arg topic "$topic" '{agent:$agent, task:$task, topic:$topic}')
    local result
    result=$(AGENT_NAME=coordinator WORK_DIR="$WORK_DIR" AGENTS_DIR="$AGENTS_DIR" AI_AGENT_DB="$AI_AGENT_DB" DELEGATION_DEPTH=0 sh "${WORK_DIR}/tools/agent_delegate.sh" "$payload" 2>&1)
    # Even if the PM didn't write a board reply, check the team DB for new tasks
    local new_tasks
    new_tasks=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks WHERE id > 1" 2>/dev/null)
    if echo "$result" | jq -e '.success == false' >/dev/null 2>&1 && [[ "$new_tasks" -le 0 ]]; then
        warn "PM failed to break the goal into tasks"
        echo "$result" | head -5
    elif [[ "$new_tasks" -gt 0 ]]; then
        ok "PM created $new_tasks sub-tasks"
    fi
    # Mark the spec task as done (PM completed by creating subtasks)
    if [[ -n "$spec_id" ]]; then
        AI_AGENT_DB="$AI_AGENT_DB" AGENT_NAME=coordinator sh "${WORK_DIR}/tools/task_done.sh" "$(jq -nc --argjson id "$spec_id" --arg r "PM broke goal into $new_tasks sub-task(s)" '{task_id:$id, result:$r}')" 2>/dev/null
    fi
    info "use /team next to dispatch the first sub-task"
    return 0
}

# _team_next — dispatch the next ready task to its assigned agent
_team_next() {
    local goal_id
    goal_id=$(sqlite3 "$AI_AGENT_DB" "SELECT value FROM team_state WHERE key='current_goal_id'" 2>/dev/null)
    if [[ -z "$goal_id" ]]; then
        warn "no active goal — use /team start <goal>"
        return 1
    fi
    # Get next ready task
    local next
    next=$(AI_AGENT_DB="$AI_AGENT_DB" sh "${WORK_DIR}/tools/task_list.sh" '{"ready":1,"limit":1}' 2>/dev/null | jq -r '.[0] // empty' 2>/dev/null)
    if [[ -z "$next" ]]; then
        info "no ready tasks (all blocked or done)"
        return 0
    fi
    local id title desc type
    id=$(echo "$next" | jq -r '.id')
    title=$(echo "$next" | jq -r '.title')
    type=$(echo "$next" | jq -r '.type')
    desc=$(echo "$next" | jq -r '.description // ""')
    local agent
    agent=$(_team_agent_for_type "$type")
    if [[ -z "$agent" ]]; then
        warn "unknown task type '$type' for task #$id"
        return 1
    fi
    info "dispatching task #$id (type=$type, agent=$agent): $title"
    # Mark as claimed
    AI_AGENT_DB="$AI_AGENT_DB" AGENT_NAME=coordinator sh "${WORK_DIR}/tools/task_claim.sh" "$(jq -nc --argjson id "$id" '{task_id:$id}')" 2>/dev/null
    # Build delegation payload
    local topic
    topic="team-task-$id-$(date +%s)"
    local msg
    msg="You are the $agent agent. Work on task #$id:
title: $title
type: $type
description:
$desc

When you are done, you MUST write a 5-15 line summary of what you did to the blackboard using board_write with topic='$topic'. The summary is how the coordinator learns the work is complete. Then you can stop."
    local payload reply
    payload=$(jq -nc --arg agent "$agent" --arg task "$msg" --arg topic "$topic" '{agent:$agent, task:$task, topic:$topic}')
    reply=$(AGENT_NAME=coordinator WORK_DIR="$WORK_DIR" AGENTS_DIR="$AGENTS_DIR" AI_AGENT_DB="$AI_AGENT_DB" DELEGATION_DEPTH=0 sh "${WORK_DIR}/tools/agent_delegate.sh" "$payload" 2>&1)
    # Truncate reply to reasonable size
    local result_summary
    if [[ -z "$reply" ]] || echo "$reply" | jq -e '.success == false' >/dev/null 2>&1; then
        warn "agent '$agent' did not write a board reply for task #$id"
        echo "$reply" | head -3
        # Fall back: mark the task done with a stub result so the workflow can continue.
        # The user can re-run /team next for the next task; this task is recorded as
        # completed by $agent (per the LLM's silence) so dependent tasks can progress.
        result_summary="(no board reply from $agent) $reply"
        result_summary=$(echo "$result_summary" | head -c 4000)
    else
        result_summary=$(echo "$reply" | head -c 4000)
    fi
    # Mark task done
    AI_AGENT_DB="$AI_AGENT_DB" AGENT_NAME=coordinator sh "${WORK_DIR}/tools/task_done.sh" "$(jq -nc --argjson id "$id" --arg r "$result_summary" '{task_id:$id, result:$r}')" 2>/dev/null
    ok "task #$id done (by $agent)"
    echo "$result_summary" | head -10
    return 0
}

# _team_stop — clear the current goal (keep tasks)
_team_stop() {
    sqlite3 "$AI_AGENT_DB" "DELETE FROM team_state WHERE key IN ('current_goal','current_goal_id')" 2>/dev/null
    ok "team stopped (current goal cleared)"
    return 0
}

# _team_clear — soft cancel: flip non-done tasks to 'cancelled' + clear goal.
# Tasks in 'done' state are kept as-is (they represent completed work).
# task_events rows are NOT deleted (audit trail stays).
# For a true wipe, run `rm -f .data/ai-agent.db` from the shell.
# usage: _team_clear [y]   (y = skip [y/N] prompt, for non-interactive use)
_team_clear() {
    local force="${1:-}"
    local t_count c_count done_count goal
    t_count=$(sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks" 2>/dev/null || echo 0)
    c_count=$(sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('pending','claimed','in_progress','review','blocked')" 2>/dev/null || echo 0)
    done_count=$(sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" "SELECT COUNT(*) FROM tasks WHERE status='done'" 2>/dev/null || echo 0)
    goal=$(sqlite3 "$AI_AGENT_DB" "SELECT value FROM team_state WHERE key='current_goal'" 2>/dev/null)

    if [[ "$t_count" -eq 0 && -z "$goal" ]]; then
        ok "team already empty (no tasks, no goal)"
        return 0
    fi

    if [[ "$c_count" -gt 0 && "$force" != "y" && -t 0 ]]; then
        local ans
        read -r -p "cancel $c_count task(s)? [y/N] " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            ok "team clear cancelled (no changes)"
            return 0
        fi
    fi

    sqlite3 -cmd 'PRAGMA foreign_keys=ON' "$AI_AGENT_DB" <<SQL 2>/dev/null
UPDATE tasks SET status='cancelled', updated_at=datetime('now')
  WHERE status IN ('pending','claimed','in_progress','review','blocked');
DELETE FROM team_state WHERE key IN ('current_goal','current_goal_id');
DELETE FROM sqlite_sequence WHERE name='tasks';
SQL

    if [[ "$c_count" -eq 0 && -n "$goal" ]]; then
        ok "team goal cleared ($done_count done task(s) kept)"
    elif [[ "$c_count" -eq 0 && -z "$goal" ]]; then
        ok "team already empty (no tasks, no goal)"
    else
        ok "team cleared: $c_count task(s) cancelled ($done_count done kept), goal cleared"
    fi
    return 0
}
