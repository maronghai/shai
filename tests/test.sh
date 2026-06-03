#!/bin/bash
# Test suite for ai-agent.sh — 21 groups, 88 sub-assertions.
# Run from anywhere:   bash tests/test.sh
# Or:                  ./tests/test.sh
set +e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export REPO
cd "$REPO"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
nok()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Helper: report a header
hr() { echo; echo "=== $1 ==="; }

hr "Test 1: agent_list returns default + 2 personas"
OUT=$(AGENTS_DIR=${REPO}/agents sh ${REPO}/tools/agent_list.sh 2>&1)
echo "$OUT" | head -3
if echo "$OUT" | jq -e '.[0].name == "default"' >/dev/null; then ok "default first"; else nok "default not first"; fi
COUNT=$(echo "$OUT" | jq 'length')
if [[ "$COUNT" -ge 7 ]]; then ok "$COUNT agents (default + 7 personas)"; else nok "expected at least 7, got $COUNT"; fi
if echo "$OUT" | jq -e '.[] | select(.name == "code-reviewer") | .description | test("read-only")' >/dev/null; then
  ok "code-reviewer description mentions read-only"
else nok "code-reviewer description wrong"; fi

hr "Test 2: code-reviewer exec_command is disabled"
OUT=$(sh ${REPO}/agents/code-reviewer/tools/exec_command.sh '{"command":"rm -rf /"}' 2>&1)
echo "$OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "returns success:false"; else nok "did not fail"; fi
if echo "$OUT" | jq -e '.error | test("disabled")' >/dev/null; then ok "error mentions 'disabled'"; else nok "wrong error"; fi

hr "Test 3: blackboard roundtrip with reply chain"
BB=/tmp/bb_$$.db
rm -f "$BB"
sqlite3 "$BB" "CREATE TABLE board (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL DEFAULT '', topic TEXT NOT NULL, payload TEXT NOT NULL, reply_to INTEGER, created_at TEXT DEFAULT (datetime('now'))); CREATE INDEX idx_board_topic ON board(topic);"

OUT=$(BLACKBOARD_DB_PATH="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_write.sh '{"topic":"x","payload":"parent"}' 2>&1)
echo "  write: $OUT"
PID=$(echo "$OUT" | jq -r '.id')
if [[ "$PID" == "1" ]]; then ok "parent id=1"; else nok "parent id wrong"; fi

OUT=$(BLACKBOARD_DB_PATH="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_write.sh "{\"topic\":\"x\",\"payload\":\"child\",\"reply_to\":$PID}" 2>&1)
echo "  reply: $OUT"
CID=$(echo "$OUT" | jq -r '.id')
if [[ "$CID" == "2" ]]; then ok "child id=2"; else nok "child id wrong"; fi

OUT=$(BLACKBOARD_DB_PATH="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_read.sh "{\"topic\":\"x\",\"since_id\":$PID}" 2>&1)
echo "  read since: $OUT"
if echo "$OUT" | jq -e 'length == 1 and .[0].payload == "child" and .[0].reply_to == 1' >/dev/null; then
  ok "since_id filter returns child with reply_to=1"
else nok "since_id wrong: $OUT"; fi

OUT=$(BLACKBOARD_DB_PATH="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_list.sh '{}' 2>&1)
echo "  list: $OUT"
# Format is [{topic}, {topic}, ...]
if echo "$OUT" | jq -e '.[0].topic == "x"' >/dev/null; then ok "list returns topics"; else nok "list format wrong"; fi

# Verify the row 2 has reply_to=1 in the DB
ROW=$(sqlite3 "$BB" "SELECT reply_to FROM board WHERE id=2")
if [[ "$ROW" == "1" ]]; then ok "DB row 2 has reply_to=1"; else nok "DB row 2 reply_to=$ROW"; fi

rm -f "$BB"

hr "Test 4: load_tools merge dedupes with last-wins"
# Simulate: base tools loaded first, then agent overrides.
# Base exec_command has a "shell" description; agent override has "DISABLED".
cat > /tmp/merge_in.json <<'JSON'
[
  {"function":{"name":"read_file"}},
  {"function":{"name":"exec_command","description":"base exec_command runs shell"}},
  {"function":{"name":"agent_delegate"}},
  {"function":{"name":"exec_command","description":"DISABLED in code-reviewer agent"}}
]
JSON
MERGED=$(jq -c 'group_by(.function.name) | map(last)' /tmp/merge_in.json)
echo "  input:  4 entries (read_file, exec_command(base), agent_delegate, exec_command(agent))"
echo "  merged: $MERGED"
LEN=$(echo "$MERGED" | jq 'length')
if [[ "$LEN" == "3" ]]; then ok "deduped to 3 tools"; else nok "expected 3, got $LEN"; fi
# The merged exec_command must be the AGENT's (the override), not the base's
EXEC_DESC=$(echo "$MERGED" | jq -r '[.[] | select(.function.name == "exec_command")][0].function.description')
if [[ "$EXEC_DESC" == "DISABLED in code-reviewer agent" ]]; then
  ok "exec_command override applied (agent's version wins)"
else nok "override did NOT win; got description: $EXEC_DESC"; fi
# All 3 expected tools present
for name in read_file exec_command agent_delegate; do
  if echo "$MERGED" | jq -e --arg n "$name" '[.[] | .function.name] | index($n)' >/dev/null; then
    ok "tool $name present"
  else nok "tool $name missing"; fi
done
rm -f /tmp/merge_in.json

hr "Test 5: agent_delegate refuses system 'default'"
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents BLACKBOARD_DB_PATH=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh '{"agent":"default","task":"x"}' 2>&1)
echo "  -> $OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "default rejected"; else nok "default not rejected"; fi

hr "Test 6: agent_delegate refuses nonexistent agent"
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents BLACKBOARD_DB_PATH=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh '{"agent":"nonexistent","task":"x"}' 2>&1)
echo "  -> $OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "nonexistent rejected"; else nok "nonexistent not rejected"; fi

hr "Test 7: agent_delegate refuses deep recursion"
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents BLACKBOARD_DB_PATH=/tmp/x.db DELEGATION_DEPTH=2 sh ${REPO}/tools/agent_delegate.sh '{"agent":"code-reviewer","task":"x"}' 2>&1)
echo "  -> $OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "depth=2 rejected"; else nok "depth=2 not rejected"; fi
if echo "$OUT" | jq -e '.error | test("depth")' >/dev/null; then ok "error mentions depth"; else nok "error wrong"; fi

hr "Test 8: agent_delegate refuses oversize task"
BIG=$(printf 'x%.0s' {1..9000})
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents BLACKBOARD_DB_PATH=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh "{\"agent\":\"code-reviewer\",\"task\":\"$BIG\"}" 2>&1)
echo "  -> (truncated)"
echo "$OUT" | head -c 200
echo
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "oversize rejected"; else nok "oversize not rejected"; fi

hr "Test 9: agent_delegate input validation (name regex)"
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents BLACKBOARD_DB_PATH=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh '{"agent":"../etc/passwd","task":"x"}' 2>&1)
echo "  -> $OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "path-traversal rejected"; else nok "path-traversal not rejected"; fi

hr "Test 10: JSON syntax of all tool manifests"
ALL_OK=1
for f in ${REPO}/tools/*.json ${REPO}/agents/*/tools/*.json; do
  if ! jq empty "$f" 2>/dev/null; then
    nok "invalid JSON: $f"
    ALL_OK=0
  fi
done
[[ $ALL_OK -eq 1 ]] && ok "all tool manifests valid JSON"

hr "Test 11: shell syntax of all scripts"
ALL_OK=1
for f in ${REPO}/tools/*.sh ${REPO}/agents/*/tools/*.sh ${REPO}/ai-agent.sh ${REPO}/lib/*.sh; do
  if ! bash -n "$f" 2>/dev/null; then
    nok "syntax error: $f"
    ALL_OK=0
  fi
done
[[ $ALL_OK -eq 1 ]] && ok "all scripts pass bash -n"

hr "Test 12: persona files have description (frontmatter or H1)"
for d in coordinator code-reviewer; do
  f=${REPO}/agents/$d/system.md
  if [[ -f "$f" ]]; then
    DESC=$(awk '
      NR > 20 { exit }
      /^---[[:space:]]*$/ { count++; if (count == 2) exit; next }
      count == 1 && /^description:/ { sub(/^description:[[:space:]]*/, ""); print; exit }
    ' "$f")
    if [[ -z "$DESC" ]]; then
      DESC=$(head -1 "$f" | sed 's/^# *//')
    fi
    if [[ -n "$DESC" ]]; then ok "$d: description = '$DESC'"; else nok "$d: empty description"; fi
  else
    nok "$d: missing system.md"
  fi
done

hr "Test 13: agent_status line format"
# The /agent command outputs several lines. Verify the field names are present
# (function lives in lib/agent.sh since v0.0.14 refactor).
MAIN_AND_LIBS="${REPO}/ai-agent.sh ${REPO}/lib/db.sh ${REPO}/lib/team.sh ${REPO}/lib/agent.sh"
if grep -q "name=%s" $MAIN_AND_LIBS \
   && grep -q "db=%s" $MAIN_AND_LIBS \
   && grep -q "msgs=%s" $MAIN_AND_LIBS \
   && grep -q "tools=%s" $MAIN_AND_LIBS; then
  ok "agent_status fields present"
else
  nok "agent_status fields missing"
fi

hr "Test 14: frontmatter helpers and tag filter"
# Check parse_frontmatter + agent_description + agent_tags + list_agents exist
# (now in lib/agent.sh since v0.0.14 refactor)
MAIN_AND_LIBS="${REPO}/ai-agent.sh ${REPO}/lib/db.sh ${REPO}/lib/team.sh ${REPO}/lib/agent.sh"
for fn in parse_frontmatter agent_description agent_tags list_agents; do
  if grep -q "^${fn}()" $MAIN_AND_LIBS; then
    ok "function $fn defined"
  else
    nok "function $fn missing"
  fi
done
# Check both personas have frontmatter
for f in coordinator code-reviewer; do
  if head -3 ${REPO}/agents/$f/system.md | grep -q "^---$"; then
    ok "$f has frontmatter marker"
  else
    nok "$f missing frontmatter"
  fi
done
# Check /agents @tag case branch
if grep -q "/agents\\\\ \\\\*" ${REPO}/ai-agent.sh; then
  ok "/agents @tag branch present"
else
  nok "/agents @tag branch missing"
fi

hr "Test 15: /hist full <id> wired in"
# /hist full <id> needs the "full <num>" regex match in the case branch
if grep -qF 'full\ [0-9]' ${REPO}/ai-agent.sh; then
  ok "/hist full <id> branch present"
else
  nok "/hist full <id> branch missing"
fi
# _hist_full must accept an optional id positional arg (now in lib/db.sh)
if grep -q 'local target_id=' $MAIN_AND_LIBS; then
  ok "_hist_full accepts optional id arg"
else
  nok "_hist_full does not accept id arg"
fi
# Functional smoke test: feed /hist full <existing_id> via stdin and look for "== full message #N =="
# Use printf to send actual newlines (ANSI-C \n would produce literal \n).
printf '/hist full 1\nexit\n' | timeout 15 bash ${REPO}/ai-agent.sh > /tmp/hist_full_smoke.txt 2>&1
if grep -q "== full message #1 ==" /tmp/hist_full_smoke.txt; then
  ok "/hist full <existing id> renders full single message"
else
  nok "/hist full <existing id> did not render (out: $(head -3 /tmp/hist_full_smoke.txt | tr '\n' '|'))"
fi
# Negative test: nonexistent id should print warning and continue (not crash REPL)
printf '/hist full 999\nexit\n' | timeout 15 bash ${REPO}/ai-agent.sh > /tmp/hist_full_smoke2.txt 2>&1
if grep -q "no message with id=999" /tmp/hist_full_smoke2.txt && ! grep -qi "command not found" /tmp/hist_full_smoke2.txt; then
  ok "/hist full 999 warns and continues"
else
  nok "/hist full 999 did not handle missing id gracefully"
fi
rm -f /tmp/hist_full_smoke.txt /tmp/hist_full_smoke2.txt

hr "Test 16: /agents numbered + /agent <id>"
# _resolve_agent_id helper must exist (now in lib/agent.sh)
MAIN_AND_LIBS="${REPO}/ai-agent.sh ${REPO}/lib/db.sh ${REPO}/lib/team.sh ${REPO}/lib/agent.sh"
if grep -q '^_resolve_agent_id()' $MAIN_AND_LIBS; then
  ok "_resolve_agent_id defined"
else
  nok "_resolve_agent_id missing"
fi
# /agents output must include a 1. 2. 3. numbered format
# Clear any saved current-agent so the output is deterministic
rm -f ${REPO}/.data/.current_agent
rm -f /tmp/agents_num.txt
printf '/agents\nexit\n' | timeout 15 bash ${REPO}/ai-agent.sh > /tmp/agents_num.txt 2>&1
if grep -qE '^\s*\*?\s*1\.\s' /tmp/agents_num.txt && grep -qE '^\s*2\.\s' /tmp/agents_num.txt; then
  ok "/agents output is numbered (1. 2. 3.)"
else
  nok "/agents output not numbered (out: $(head -10 /tmp/agents_num.txt | tr '\n' '|'))"
fi
# /agent 1 must switch to default (id 1 = default)
rm -f /tmp/agent_id1.txt
printf '/agent 1\n/agent\n/exit\n' | timeout 15 bash ${REPO}/ai-agent.sh > /tmp/agent_id1.txt 2>&1
if grep -q "Switched to: default" /tmp/agent_id1.txt; then
  ok "/agent 1 switches to default"
else
  nok "/agent 1 did not switch to default (out: $(cat /tmp/agent_id1.txt | tr '\n' '|'))"
fi
# /agent 99 must warn (out of range) but not crash
rm -f /tmp/agent_id99.txt
printf '/agent 99\nexit\n' | timeout 15 bash ${REPO}/ai-agent.sh > /tmp/agent_id99.txt 2>&1
if grep -q "no agent with id 99" /tmp/agent_id99.txt && ! grep -qi "command not found" /tmp/agent_id99.txt; then
  ok "/agent 99 warns about out-of-range id"
else
  nok "/agent 99 did not warn (out: $(cat /tmp/agent_id99.txt | tr '\n' '|'))"
fi
# /agent <name> must still work (regression)
rm -f /tmp/agent_name.txt
printf '/agent code-reviewer\n/agent\n/exit\n' | timeout 15 bash ${REPO}/ai-agent.sh > /tmp/agent_name.txt 2>&1
if grep -q "Switched to: code-reviewer" /tmp/agent_name.txt; then
  ok "/agent <name> still works (regression)"
else
  nok "/agent <name> broke (out: $(cat /tmp/agent_name.txt | tr '\n' '|'))"
fi
rm -f /tmp/agents_num.txt /tmp/agent_id1.txt /tmp/agent_id99.txt /tmp/agent_name.txt

hr "Test 17: REPL prompt shows agent info"
# _agent_prompt function must exist (now in lib/agent.sh)
MAIN_AND_LIBS="${REPO}/ai-agent.sh ${REPO}/lib/db.sh ${REPO}/lib/team.sh ${REPO}/lib/agent.sh"
if grep -q '^_agent_prompt()' $MAIN_AND_LIBS; then
  ok "_agent_prompt defined"
else
  nok "_agent_prompt missing"
fi
# main loop must call _agent_prompt in the read -p
if grep -qF 'read -e -p "$(_agent_prompt)"' ${REPO}/ai-agent.sh; then
  ok "main loop uses _agent_prompt"
else
  nok "main loop does not use _agent_prompt"
fi
# Extract the _agent_prompt function and test it in isolation
# Since v0.0.14 refactor, helpers live in lib/agent.sh.
TMPF=$(mktemp /tmp/agent_prompt_test_XXXX.sh)
cat > "$TMPF" <<'BASH'
#!/bin/bash
set -e
F="${REPO}/lib/agent.sh"
WORK_DIR=${REPO}
AGENTS_DIR=${REPO}/agents
R=$'\033[0m'; B=$'\033[1;34m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; D=$'\033[2m'
eval "$(awk '/^parse_frontmatter\(\)/,/^}$/' $F)"
eval "$(awk '/^agent_description\(\)/,/^}$/' $F)"
eval "$(awk '/^agent_tags\(\)/,/^}$/' $F)"
eval "$(awk '/^_agent_prompt\(\)/,/^}$/' $F)"
CURRENT_AGENT=""
out_default="$(_agent_prompt)"
CURRENT_AGENT="code-reviewer"
out_cr="$(_agent_prompt)"
CURRENT_AGENT="coordinator"
out_coord="$(_agent_prompt)"
# Strip ANSI for assertion
strip() { printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g'; }
echo "DEFAULT=$(strip "$out_default")"
echo "CR=$(strip "$out_cr")"
echo "COORD=$(strip "$out_coord")"
BASH
chmod +x "$TMPF"
OUT=$("$TMPF" 2>&1)
rm -f "$TMPF"
if echo "$OUT" | grep -q "DEFAULT=You \[default\]> "; then
  ok "default prompt shows 'You [default]>'"
else
  nok "default prompt wrong ($OUT)"
fi
if echo "$OUT" | grep -qE "CR=You \[code-reviewer.*\]> "; then
  ok "code-reviewer prompt shows 'You [code-reviewer · ...]>'"
else
  nok "code-reviewer prompt wrong ($OUT)"
fi
if echo "$OUT" | grep -qE "COORD=You \[coordinator.*\]> "; then
  ok "coordinator prompt shows 'You [coordinator · ...]>'"
else
  nok "coordinator prompt wrong ($OUT)"
fi
# Truncation: long desc should produce ellipsis
if echo "$OUT" | grep -qE "CR=You \[code-reviewer[^]]*…\]> "; then
  ok "long description is truncated (ellipsis present)"
else
  nok "long description NOT truncated (no ellipsis in code-reviewer prompt)"
fi
# The prompt must contain REAL ESC bytes (0x1b), not literal "\033" text.
# A previous bug used printf '%s' which left the escapes uninterpreted, so the
# terminal printed "\033[1;34m" as plain text. The fix uses printf '%b'.
TMPRAW=$(mktemp /tmp/agent_prompt_raw_XXXX.txt)
cat > "$TMPRAW.sh" <<'BASH'
#!/bin/bash
F="${REPO}/lib/agent.sh"
WORK_DIR=${REPO}
AGENTS_DIR=${REPO}/agents
R=$'\033[0m'; B=$'\033[1;34m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; D=$'\033[2m'
eval "$(awk '/^parse_frontmatter\(\)/,/^}$/' $F)"
eval "$(awk '/^agent_description\(\)/,/^}$/' $F)"
eval "$(awk '/^agent_tags\(\)/,/^}$/' $F)"
eval "$(awk '/^_agent_prompt\(\)/,/^}$/' $F)"
CURRENT_AGENT="code-reviewer"
_agent_prompt
BASH
chmod +x "$TMPRAW.sh"
RAW=$("$TMPRAW.sh" 2>&1)
rm -f "$TMPRAW.sh"
# Hex first 4 bytes: should start with 1b 5b (ESC [) for ANSI, not literal "\033"
FIRST=$(printf '%s' "$RAW" | xxd -l 4 -p)
if [[ "$FIRST" == "1b5b"* ]]; then
  ok "_agent_prompt emits real ESC bytes (0x1b), not literal '\\\\033' text"
else
  nok "_agent_prompt does not emit ESC bytes; first bytes are: $FIRST"
fi

hr "Test 18: /tasks and /task commands"
# Init team DB and seed
rm -f "$REPO/.data/team.db" 2>/dev/null
sqlite3 "$REPO/.data/team.db" < "$REPO/team/schema.sql" 2>/dev/null
sqlite3 "$REPO/.data/team.db" "DELETE FROM tasks; DELETE FROM task_events; DELETE FROM team_state; DELETE FROM sqlite_sequence;" 2>/dev/null
TEAM_DB_PATH="$REPO/.data/team.db" AGENT_NAME=pm \
  sh "$REPO/tools/task_create.sh" '{"title":"design X","description":"spec","type":"design"}' > /dev/null
TEAM_DB_PATH="$REPO/.data/team.db" AGENT_NAME=pm \
  sh "$REPO/tools/task_create.sh" '{"title":"impl X","description":"code","type":"code","depends_on":"1","priority":5}' > /dev/null

# /tasks branch in main script
if grep -q "/tasks)" "${REPO}/ai-agent.sh" && grep -qE '/tasks[ \\*].*ready' "${REPO}/ai-agent.sh"; then
  ok "/tasks command present in main script (with /tasks ready variant)"
else
  nok "/tasks command not found in main script"
fi

if grep -qE '/task[ \\]' "${REPO}/ai-agent.sh" && grep -q "task_show" "${REPO}/ai-agent.sh"; then
  ok "/task <id> command present in main script"
else
  nok "/task <id> command not found in main script"
fi

# task_list output
out=$(TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_list.sh" '{}' 2>/dev/null)
count=$(echo "$out" | jq 'length' 2>/dev/null)
if [[ "$count" == "2" ]]; then
  ok "task_list returns 2 tasks"
else
  nok "task_list count is $count, expected 2"
fi

# task_list ready=1
ready=$(TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_list.sh" '{"ready":1}' | jq -r '.[].id' 2>/dev/null | tr '\n' ' ')
if [[ "$ready" == "1 " ]]; then
  ok "task_list ready=1 returns only task 1 (task 2 blocked by dep)"
else
  nok "task_list ready=1 returned '$ready' (expected '1 ')"
fi

# task_show output
show=$(TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_show.sh" '{"task_id":1}' 2>/dev/null)
success=$(echo "$show" | jq -r '.success' 2>/dev/null)
title=$(echo "$show" | jq -r '.task.title' 2>/dev/null)
events_len=$(echo "$show" | jq -r '.events | length' 2>/dev/null)
if [[ "$success" == "true" ]] && [[ "$title" == "design X" ]] && [[ "$events_len" == "1" ]]; then
  ok "task_show returns task 1 with 1 event (created)"
else
  nok "task_show: success=$success title='$title' events=$events_len"
fi

# task_show missing
missing=$(TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_show.sh" '{"task_id":99}' 2>/dev/null)
if echo "$missing" | jq -e '.success == false' > /dev/null 2>&1; then
  ok "task_show for missing id returns success=false"
else
  nok "task_show for missing id did not return error: $missing"
fi

# task_show handles real newlines/quotes in fields
nl_title="NewlineTask_$$"
TEAM_DB_PATH="$REPO/.data/team.db" AGENT_NAME=pm \
  sh "$REPO/tools/task_create.sh" "{\"title\":\"$nl_title\",\"description\":\"line1\nline2 \\\"q\\\"\",\"type\":\"docs\"}" > /dev/null
newline_id=$(TEAM_DB_PATH="$REPO/.data/team.db" sqlite3 "$REPO/.data/team.db" "SELECT id FROM tasks WHERE title='$nl_title'" 2>/dev/null)
nl_show=$(TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_show.sh" "{\"task_id\":$newline_id}" 2>/dev/null)
nl_desc=$(echo "$nl_show" | jq -r '.task.description' 2>/dev/null)
if [[ "$nl_desc" == $'line1\nline2 "q"' ]]; then
  ok "task_show preserves newlines and quotes in description"
else
  nok "task_show failed to preserve newlines/quotes: '$nl_desc'"
fi

hr "Test 19: 6 personas (pm/architect/developer/tester/docs + code-reviewer + coordinator)"

# All 6 new persona system.md files exist
for p in pm architect developer tester docs; do
    if [[ -f "$REPO/agents/$p/system.md" ]]; then
      ok "agents/$p/system.md exists"
    else
      nok "agents/$p/system.md missing"
    fi
    # Frontmatter present
    if head -3 "$REPO/agents/$p/system.md" | grep -q "^---$"; then
      ok "agents/$p has frontmatter marker"
    else
      nok "agents/$p missing frontmatter"
    fi
    # type: tag present (use role-specific mapping)
    case "$p" in
      pm)         expected_type="type:pm" ;;
      architect)  expected_type="type:design" ;;
      developer)  expected_type="type:code" ;;
      tester)     expected_type="type:test" ;;
      docs)       expected_type="type:docs" ;;
    esac
    if head -5 "$REPO/agents/$p/system.md" | grep -qE "tags:.*$expected_type"; then
      ok "agents/$p has '$expected_type' tag"
    else
      nok "agents/$p missing '$expected_type' tag"
    fi
done

# agent_list returns all 6+1
out=$(AGENTS_DIR="$REPO/agents" sh "$REPO/tools/agent_list.sh" 2>/dev/null)
count=$(echo "$out" | jq 'length' 2>/dev/null)
if [[ "$count" == "8" ]]; then
  ok "agent_list returns 8 agents (default + 7 named)"
else
  nok "agent_list count = $count, expected 8"
fi

# Switch to each persona
for p in pm architect developer tester docs; do
    out=$(echo "/agent $p" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "Switched to: $p")
    if [[ -n "$out" ]]; then
      ok "/agent $p switches"
    else
      nok "/agent $p did not switch"
    fi
done

# Tag filter (@design returns architect)
out=$(echo "/agents @design" | timeout 3 bash ai-agent.sh 2>&1)
if echo "$out" | grep -q "Architect"; then
  ok "/agents @design includes architect"
else
  nok "/agents @design did not show architect"
fi

hr "Test 20: /team commands (manual-but-scripted workflow)"
# /team status with no goal
rm -f "$REPO/.data/team.db" 2>/dev/null
sqlite3 "$REPO/.data/team.db" "DELETE FROM tasks; DELETE FROM task_events; DELETE FROM team_state; DELETE FROM sqlite_sequence;" 2>/dev/null
out=$(echo "/team" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "(none — use /team start")
if [[ -n "$out" ]]; then
  ok "/team status with no goal shows hint"
else
  nok "/team status did not show no-goal hint"
fi

# /team status with tasks (seeded)
sqlite3 "$REPO/.data/team.db" < "$REPO/team/schema.sql" 2>/dev/null
TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_create.sh" '{"title":"design X","description":"d","type":"design"}' > /dev/null
TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_create.sh" '{"title":"code X","description":"c","type":"code","depends_on":"1"}' > /dev/null
sqlite3 "$REPO/.data/team.db" "INSERT INTO team_state VALUES ('current_goal', 'add X', datetime('now')), ('current_goal_id', '1', datetime('now'))" 2>/dev/null
out=$(echo "/team" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "add X (id=1)")
if [[ -n "$out" ]]; then
  ok "/team status shows current goal and id"
else
  nok "/team status did not show goal"
fi

# /team status shows ready count
out=$(echo "/team" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "ready:   1 task")
if [[ -n "$out" ]]; then
  ok "/team status shows 1 ready task"
else
  nok "/team status did not show ready count"
fi

# Verify the team_state table exists in the schema
if grep -q "CREATE TABLE.*team_state" "$REPO/team/schema.sql"; then
  ok "team_state table defined in schema.sql"
else
  nok "team_state table missing from schema.sql"
fi

# Verify _team_status, _team_start, _team_next, _team_stop are defined
# (now in lib/team.sh since v0.0.14 refactor)
MAIN_AND_LIBS="${REPO}/ai-agent.sh ${REPO}/lib/db.sh ${REPO}/lib/team.sh ${REPO}/lib/agent.sh"
for fn in _team_status _team_start _team_next _team_stop _team_agent_for_type; do
    if grep -qE "^${fn}\(\)" $MAIN_AND_LIBS; then
      ok "$fn function defined"
    else
      nok "$fn function missing"
    fi
done

# Type-to-agent mapping test (now in lib/team.sh since v0.0.14 refactor)
out=$(F="${REPO}/lib/team.sh" bash -c '
eval "$(awk "/^_team_agent_for_type\\(\\)/,/^}$/" "$F")"
for t in spec design code review test docs meta; do
    echo -n "$t:$(_team_agent_for_type $t) "
done
')
case "$out" in
  *spec:pm*design:architect*code:developer*review:code-reviewer*test:tester*docs:docs*meta:coordinator*)
    ok "type -> agent mapping correct (pm/architect/developer/code-reviewer/tester/docs/coordinator)" ;;
  *)
    nok "type -> agent mapping wrong: $out" ;;
esac

hr "Test 21: /team clear soft-cancels (no data loss)"
# Seed 3 tasks (2 pending + 1 done) + goal
rm -f "$REPO/.data/team.db" 2>/dev/null
sqlite3 "$REPO/.data/team.db" < "$REPO/team/schema.sql" 2>/dev/null
sqlite3 "$REPO/.data/team.db" "DELETE FROM tasks; DELETE FROM task_events; DELETE FROM team_state; DELETE FROM sqlite_sequence;" 2>/dev/null
TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_create.sh" '{"title":"pending-1","type":"design"}' > /dev/null
TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_create.sh" '{"title":"pending-2","type":"code","depends_on":"1"}' > /dev/null
TEAM_DB_PATH="$REPO/.data/team.db" sh "$REPO/tools/task_create.sh" '{"title":"done-task","type":"test"}' > /dev/null
sqlite3 "$REPO/.data/team.db" "UPDATE tasks SET status='done' WHERE id=3; INSERT INTO task_events VALUES (NULL, 3, 'developer', 'done', 'completed', datetime('now'));" 2>/dev/null
sqlite3 "$REPO/.data/team.db" "INSERT INTO team_state VALUES ('current_goal','test goal',datetime('now')),('current_goal_id','1',datetime('now'))" 2>/dev/null

# 21a: soft cancel flips pending -> cancelled, done stays, goal cleared
out=$(echo "/team clear -y" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "2 task(s) cancelled")
if [[ -n "$out" ]]; then
  ok "/team clear flips 2 pending tasks to 'cancelled'"
else
  nok "/team clear did not flip pending tasks: $out"
fi
# Verify rows preserved
n=$(sqlite3 "$REPO/.data/team.db" "SELECT (SELECT COUNT(*) FROM tasks) || ',' || (SELECT COUNT(*) FROM tasks WHERE status='cancelled') || ',' || (SELECT COUNT(*) FROM tasks WHERE status='done') || ',' || (SELECT COUNT(*) FROM team_state WHERE key='current_goal')")
if [[ "$n" == "3,2,1,0" ]]; then
  ok "rows preserved: 3 total, 2 cancelled, 1 done, goal cleared"
else
  nok "wrong state after /team clear: total/cancelled/done/goal_remaining = $n"
fi

# 21b: idempotent on already-cleared
out=$(echo "/team clear" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "team already empty")
if [[ -n "$out" ]]; then
  ok "/team clear idempotent (no goal, no non-done tasks)"
else
  nok "/team clear not idempotent: $out"
fi

# 21c: -y and --yes both work
sqlite3 "$REPO/.data/team.db" "UPDATE tasks SET status='pending' WHERE id IN (1,2); INSERT INTO team_state VALUES ('current_goal','g2',datetime('now')),('current_goal_id','1',datetime('now'))" 2>/dev/null
out=$(echo "/team clear -y" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "2 task(s) cancelled")
[[ -n "$out" ]] && ok "/team clear -y works" || nok "/team clear -y failed: $out"
sqlite3 "$REPO/.data/team.db" "UPDATE tasks SET status='pending' WHERE id IN (1,2); INSERT INTO team_state VALUES ('current_goal','g3',datetime('now'))" 2>/dev/null
out=$(echo "/team clear --yes" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "2 task(s) cancelled")
[[ -n "$out" ]] && ok "/team clear --yes works" || nok "/team clear --yes failed: $out"

# 21d: bad flag → usage
out=$(echo "/team clear foo" | timeout 3 bash ai-agent.sh 2>&1 | grep -F "usage: /team clear")
[[ -n "$out" ]] && ok "/team clear foo → usage hint" || nok "/team clear foo did not show usage: $out"

# 21e: _team_clear + /team clear case wired (now in lib/team.sh)
if grep -qE '^_team_clear\(\)' $MAIN_AND_LIBS; then
  ok "_team_clear function defined"
else
  nok "_team_clear function missing"
fi
if grep -qE '/team\\ clear' "${REPO}/ai-agent.sh"; then
  ok "/team clear case wired in REPL"
else
  nok "/team clear case not wired"
fi

hr "Summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
