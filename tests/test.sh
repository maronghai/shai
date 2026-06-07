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

OUT=$(AI_AGENT_DB="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_write.sh '{"topic":"x","payload":"parent"}' 2>&1)
echo "  write: $OUT"
PID=$(echo "$OUT" | jq -r '.id')
if [[ "$PID" == "1" ]]; then ok "parent id=1"; else nok "parent id wrong"; fi

OUT=$(AI_AGENT_DB="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_write.sh "{\"topic\":\"x\",\"payload\":\"child\",\"reply_to\":$PID}" 2>&1)
echo "  reply: $OUT"
CID=$(echo "$OUT" | jq -r '.id')
if [[ "$CID" == "2" ]]; then ok "child id=2"; else nok "child id wrong"; fi

OUT=$(AI_AGENT_DB="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_read.sh "{\"topic\":\"x\",\"since_id\":$PID}" 2>&1)
echo "  read since: $OUT"
if echo "$OUT" | jq -e 'length == 1 and .[0].payload == "child" and .[0].reply_to == 1' >/dev/null; then
  ok "since_id filter returns child with reply_to=1"
else nok "since_id wrong: $OUT"; fi

OUT=$(AI_AGENT_DB="$BB" AGENT_NAME="t" WORK_DIR=/tmp sh ${REPO}/tools/board_list.sh '{}' 2>&1)
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
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents AI_AGENT_DB=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh '{"agent":"default","task":"x"}' 2>&1)
echo "  -> $OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "default rejected"; else nok "default not rejected"; fi

hr "Test 6: agent_delegate refuses nonexistent agent"
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents AI_AGENT_DB=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh '{"agent":"nonexistent","task":"x"}' 2>&1)
echo "  -> $OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "nonexistent rejected"; else nok "nonexistent not rejected"; fi

hr "Test 7: agent_delegate refuses deep recursion"
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents AI_AGENT_DB=/tmp/x.db DELEGATION_DEPTH=2 sh ${REPO}/tools/agent_delegate.sh '{"agent":"code-reviewer","task":"x"}' 2>&1)
echo "  -> $OUT"
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "depth=2 rejected"; else nok "depth=2 not rejected"; fi
if echo "$OUT" | jq -e '.error | test("depth")' >/dev/null; then ok "error mentions depth"; else nok "error wrong"; fi

hr "Test 8: agent_delegate refuses oversize task"
BIG=$(printf 'x%.0s' {1..9000})
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents AI_AGENT_DB=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh "{\"agent\":\"code-reviewer\",\"task\":\"$BIG\"}" 2>&1)
echo "  -> (truncated)"
echo "$OUT" | head -c 200
echo
if echo "$OUT" | jq -e '.success == false' >/dev/null; then ok "oversize rejected"; else nok "oversize not rejected"; fi

hr "Test 9: agent_delegate input validation (name regex)"
OUT=$(AGENT_NAME="default" WORK_DIR=${REPO} AGENTS_DIR=${REPO}/agents AI_AGENT_DB=/tmp/x.db DELEGATION_DEPTH=0 sh ${REPO}/tools/agent_delegate.sh '{"agent":"../etc/passwd","task":"x"}' 2>&1)
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
rm -f "$REPO/.data/ai-agent.db" 2>/dev/null
sqlite3 "$REPO/.data/ai-agent.db" < "$REPO/team/schema.sql" 2>/dev/null
sqlite3 "$REPO/.data/ai-agent.db" "DELETE FROM tasks; DELETE FROM task_events; DELETE FROM team_state; DELETE FROM sqlite_sequence;" 2>/dev/null
AI_AGENT_DB="$REPO/.data/ai-agent.db" AGENT_NAME=pm \
  sh "$REPO/tools/task_create.sh" '{"title":"design X","description":"spec","type":"design"}' > /dev/null
AI_AGENT_DB="$REPO/.data/ai-agent.db" AGENT_NAME=pm \
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
out=$(AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_list.sh" '{}' 2>/dev/null)
count=$(echo "$out" | jq 'length' 2>/dev/null)
if [[ "$count" == "2" ]]; then
  ok "task_list returns 2 tasks"
else
  nok "task_list count is $count, expected 2"
fi

# task_list ready=1
ready=$(AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_list.sh" '{"ready":1}' | jq -r '.[].id' 2>/dev/null | tr '\n' ' ')
if [[ "$ready" == "1 " ]]; then
  ok "task_list ready=1 returns only task 1 (task 2 blocked by dep)"
else
  nok "task_list ready=1 returned '$ready' (expected '1 ')"
fi

# task_show output
show=$(AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_show.sh" '{"task_id":1}' 2>/dev/null)
success=$(echo "$show" | jq -r '.success' 2>/dev/null)
title=$(echo "$show" | jq -r '.task.title' 2>/dev/null)
events_len=$(echo "$show" | jq -r '.events | length' 2>/dev/null)
if [[ "$success" == "true" ]] && [[ "$title" == "design X" ]] && [[ "$events_len" == "1" ]]; then
  ok "task_show returns task 1 with 1 event (created)"
else
  nok "task_show: success=$success title='$title' events=$events_len"
fi

# task_show missing
missing=$(AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_show.sh" '{"task_id":99}' 2>/dev/null)
if echo "$missing" | jq -e '.success == false' > /dev/null 2>&1; then
  ok "task_show for missing id returns success=false"
else
  nok "task_show for missing id did not return error: $missing"
fi

# task_show handles real newlines/quotes in fields
nl_title="NewlineTask_$$"
AI_AGENT_DB="$REPO/.data/ai-agent.db" AGENT_NAME=pm \
  sh "$REPO/tools/task_create.sh" "{\"title\":\"$nl_title\",\"description\":\"line1\nline2 \\\"q\\\"\",\"type\":\"docs\"}" > /dev/null
newline_id=$(AI_AGENT_DB="$REPO/.data/ai-agent.db" sqlite3 "$REPO/.data/ai-agent.db" "SELECT id FROM tasks WHERE title='$nl_title'" 2>/dev/null)
nl_show=$(AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_show.sh" "{\"task_id\":$newline_id}" 2>/dev/null)
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
    out=$(echo "/agent $p" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "Switched to: $p")
    if [[ -n "$out" ]]; then
      ok "/agent $p switches"
    else
      nok "/agent $p did not switch"
    fi
done

# Tag filter (@design returns architect)
out=$(echo "/agents @design" | timeout 10 bash ai-agent.sh 2>&1)
if echo "$out" | grep -q "Architect"; then
  ok "/agents @design includes architect"
else
  nok "/agents @design did not show architect"
fi

hr "Test 20: /team commands (manual-but-scripted workflow)"
# /team status with no goal
rm -f "$REPO/.data/ai-agent.db" 2>/dev/null
sqlite3 "$REPO/.data/ai-agent.db" "DELETE FROM tasks; DELETE FROM task_events; DELETE FROM team_state; DELETE FROM sqlite_sequence;" 2>/dev/null
out=$(echo "/team" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "(none — use /team start")
if [[ -n "$out" ]]; then
  ok "/team status with no goal shows hint"
else
  nok "/team status did not show no-goal hint"
fi

# /team status with tasks (seeded)
sqlite3 "$REPO/.data/ai-agent.db" < "$REPO/team/schema.sql" 2>/dev/null
AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_create.sh" '{"title":"design X","description":"d","type":"design"}' > /dev/null
AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_create.sh" '{"title":"code X","description":"c","type":"code","depends_on":"1"}' > /dev/null
sqlite3 "$REPO/.data/ai-agent.db" "INSERT INTO team_state VALUES ('current_goal', 'add X', datetime('now')), ('current_goal_id', '1', datetime('now'))" 2>/dev/null
out=$(echo "/team" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "add X (id=1)")
if [[ -n "$out" ]]; then
  ok "/team status shows current goal and id"
else
  nok "/team status did not show goal"
fi

# /team status shows ready count
out=$(echo "/team" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "ready:   1 task")
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
rm -f "$REPO/.data/ai-agent.db" 2>/dev/null
sqlite3 "$REPO/.data/ai-agent.db" < "$REPO/team/schema.sql" 2>/dev/null
sqlite3 "$REPO/.data/ai-agent.db" "DELETE FROM tasks; DELETE FROM task_events; DELETE FROM team_state; DELETE FROM sqlite_sequence;" 2>/dev/null
AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_create.sh" '{"title":"pending-1","type":"design"}' > /dev/null
AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_create.sh" '{"title":"pending-2","type":"code","depends_on":"1"}' > /dev/null
AI_AGENT_DB="$REPO/.data/ai-agent.db" sh "$REPO/tools/task_create.sh" '{"title":"done-task","type":"test"}' > /dev/null
sqlite3 "$REPO/.data/ai-agent.db" "UPDATE tasks SET status='done' WHERE id=3; INSERT INTO task_events VALUES (NULL, 3, 'developer', 'done', 'completed', datetime('now'));" 2>/dev/null
sqlite3 "$REPO/.data/ai-agent.db" "INSERT INTO team_state VALUES ('current_goal','test goal',datetime('now')),('current_goal_id','1',datetime('now'))" 2>/dev/null

# 21a: soft cancel flips pending -> cancelled, done stays, goal cleared
out=$(echo "/team clear -y" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "2 task(s) cancelled")
if [[ -n "$out" ]]; then
  ok "/team clear flips 2 pending tasks to 'cancelled'"
else
  nok "/team clear did not flip pending tasks: $out"
fi
# Verify rows preserved
n=$(sqlite3 "$REPO/.data/ai-agent.db" "SELECT (SELECT COUNT(*) FROM tasks) || ',' || (SELECT COUNT(*) FROM tasks WHERE status='cancelled') || ',' || (SELECT COUNT(*) FROM tasks WHERE status='done') || ',' || (SELECT COUNT(*) FROM team_state WHERE key='current_goal')")
if [[ "$n" == "3,2,1,0" ]]; then
  ok "rows preserved: 3 total, 2 cancelled, 1 done, goal cleared"
else
  nok "wrong state after /team clear: total/cancelled/done/goal_remaining = $n"
fi

# 21b: idempotent on already-cleared
out=$(echo "/team clear" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "team already empty")
if [[ -n "$out" ]]; then
  ok "/team clear idempotent (no goal, no non-done tasks)"
else
  nok "/team clear not idempotent: $out"
fi

# 21c: -y and --yes both work
sqlite3 "$REPO/.data/ai-agent.db" "UPDATE tasks SET status='pending' WHERE id IN (1,2); INSERT INTO team_state VALUES ('current_goal','g2',datetime('now')),('current_goal_id','1',datetime('now'))" 2>/dev/null
out=$(echo "/team clear -y" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "2 task(s) cancelled")
[[ -n "$out" ]] && ok "/team clear -y works" || nok "/team clear -y failed: $out"
sqlite3 "$REPO/.data/ai-agent.db" "UPDATE tasks SET status='pending' WHERE id IN (1,2); INSERT INTO team_state VALUES ('current_goal','g3',datetime('now'))" 2>/dev/null
out=$(echo "/team clear --yes" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "2 task(s) cancelled")
[[ -n "$out" ]] && ok "/team clear --yes works" || nok "/team clear --yes failed: $out"

# 21d: bad flag → usage
out=$(echo "/team clear foo" | timeout 10 bash ai-agent.sh 2>&1 | grep -F "usage: /team clear")
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

hr "Test 22: depth-aware tool stripping in run_non_interactive"

# 22a: comment block explaining the policy exists
if grep -qE 'Defense in depth|agent_delegate.{0,40}gated by DELEGATION_DEPTH' "${REPO}/ai-agent.sh"; then
  ok "depth-aware strip has explanatory comment"
else
  nok "explanatory comment missing"
fi

# 22b: condition `(( depth >= 2 ))` exists in run_non_interactive
if grep -qE 'depth >= 2' "${REPO}/ai-agent.sh"; then
  ok "depth >= 2 check present"
else
  nok "depth >= 2 check missing"
fi

# 22c: agent_delegate is NOT hard-coded in the unconditional jq filter
# (i.e. there should NOT be a single line that always strips both exec_command and agent_delegate)
if grep -qE 'function\.name != "exec_command" and \.function\.name != "agent_delegate"\)\)' "${REPO}/ai-agent.sh"; then
  nok "agent_delegate still hard-stripped unconditionally"
else
  ok "agent_delegate strip is conditional on depth"
fi

# 22d: exec_command is always stripped (defense in depth)
if grep -qE 'jq_filter='\''.function\.name != "exec_command"' "${REPO}/ai-agent.sh"; then
  ok "exec_command always stripped"
else
  nok "exec_command strip missing"
fi

# 22e: when depth >= 2, the filter should also strip agent_delegate
# (look for the conditional branch adding the second clause)
if grep -qE 'function\.name != "exec_command" and \.function\.name != "agent_delegate"'\''' "${REPO}/ai-agent.sh"; then
  ok "depth >= 2 branch strips agent_delegate"
else
  nok "depth >= 2 branch does not add agent_delegate strip"
fi

# 22f: tool_descriptions grep is also conditional (exec_command always, agent_delegate only at depth >= 2)
if grep -qF 'exec_command|agent_delegate' "${REPO}/ai-agent.sh"; then
  ok "tool_descriptions grep branches on depth"
else
  nok "tool_descriptions grep is not depth-aware"
fi

hr "Test 23: /task and /tasks empty/no-arg cases"

# Set up a fresh DB for these tests so we know exactly what tasks exist
TEST_TEAM_DB=/tmp/ai-agent-test-23-$$.db
export TEST_TEAM_DB
cp "${REPO}/.data/ai-agent.db" "$TEST_TEAM_DB" 2>/dev/null || {
  # If main DB missing, create a fresh one
  mkdir -p "${REPO}/.data"
  TEST_TEAM_DB="${REPO}/.data/ai-agent.db"
  sqlite3 "$TEST_TEAM_DB" < "${REPO}/team/schema.sql"
}

# 23a: /task (no arg) shows usage hint instead of falling through to LLM
out=$(echo -e "/task\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "usage: /task <id>" | head -1)
[[ -n "$out" ]] && ok "/task (no arg) shows usage" || nok "/task (no arg) did not show usage: $out"

# 23b: /task abc (non-numeric) still shows usage
out=$(echo -e "/task abc\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "usage: /task <id>" | head -1)
[[ -n "$out" ]] && ok "/task abc (non-numeric) shows usage" || nok "/task abc did not show usage: $out"

# 23c: /task <id> with valid id still works (id 1 should exist in DB)
out=$(echo -e "/task 1\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -E "^ID 1 \[")
[[ -n "$out" ]] && ok "/task 1 (valid id) still works" || nok "/task 1 did not render: $out"

# 23d: /task 9999 (missing id) shows error, not silent fall-through to LLM
out=$(echo -e "/task 9999\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "task 9999 not found" | head -1)
[[ -n "$out" ]] && ok "/task 9999 shows 'not found'" || nok "/task 9999 did not show not-found: $out"

# 23e: /tasks with empty DB shows "no tasks" instead of being silent
EMPTY_DB=/tmp/ai-agent-empty-$$.db
sqlite3 "$EMPTY_DB" < "${REPO}/team/schema.sql" 2>/dev/null
out=$(AI_AGENT_DB="$EMPTY_DB" bash -c 'echo -e "/tasks\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1' REPO="${REPO}" | grep -F "no tasks" | head -1)
[[ -n "$out" ]] && ok "/tasks (empty DB) shows 'no tasks'" || nok "/tasks (empty DB) silent: $out"

# 23f: /tasks with status filter that matches nothing shows specific message
out=$(AI_AGENT_DB="$EMPTY_DB" bash -c 'echo -e "/tasks pending\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1' REPO="${REPO}" | grep -F "no tasks with status 'pending'" | head -1)
[[ -n "$out" ]] && ok "/tasks pending (empty DB) shows 'no tasks with status'" || nok "/tasks pending silent: $out"

# 23g: /tasks ready with no ready tasks shows "no ready tasks"
out=$(AI_AGENT_DB="$EMPTY_DB" bash -c 'echo -e "/tasks ready\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1' REPO="${REPO}" | grep -F "no ready tasks" | head -1)
[[ -n "$out" ]] && ok "/tasks ready (empty DB) shows 'no ready tasks'" || nok "/tasks ready silent: $out"

rm -f "$EMPTY_DB" "$TEST_TEAM_DB"

# 23h: /task and /tasks work when run from a different cwd (paths must be absolute)
out=$(cd /tmp && echo -e "/tasks\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -E "^\[.+(canc|done|pend|rev|bloc)/" | head -1)
[[ -n "$out" ]] && ok "/tasks works from /tmp cwd" || nok "/tasks failed from /tmp: $(cd /tmp && echo -e "/tasks\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | tail -3)"

out=$(cd /tmp && echo -e "/task 1\nexit" | timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -E "^ID 1 \[" | head -1)
[[ -n "$out" ]] && ok "/task 1 works from /tmp cwd" || nok "/task 1 failed from /tmp"

hr "Test 24: /task clear (soft) vs /task clear -y (hard)"

# Helper: seed a DB with a known mix of tasks + a goal + a couple of events
seed_t24_db() {
    local db="$1"
    sqlite3 "$db" "DELETE FROM tasks; DELETE FROM task_events; DELETE FROM team_state;"
    AI_AGENT_DB="$db" sh "${REPO}/tools/task_create.sh" '{"title":"p1","type":"code"}' >/dev/null
    AI_AGENT_DB="$db" sh "${REPO}/tools/task_create.sh" '{"title":"p2","type":"test"}' >/dev/null
    AI_AGENT_DB="$db" sh "${REPO}/tools/task_create.sh" '{"title":"d1","type":"docs"}' >/dev/null
    sqlite3 "$db" "UPDATE tasks SET status='done' WHERE title='d1';"
    # Add 1 created event per task so we can verify hard delete removes events
    sqlite3 "$db" "INSERT INTO task_events (task_id,event) SELECT id,'created' FROM tasks;"
    sqlite3 "$db" "INSERT INTO team_state (key,value) VALUES ('current_goal','keep me');"
}

T24_DB=/tmp/ai-agent-test-24-$$.db
sqlite3 "$T24_DB" < "${REPO}/team/schema.sql" 2>/dev/null

# 24a: help text mentions /task clear with both modes
if grep -qE '/task clear' "${REPO}/ai-agent.sh" && \
   grep -qE 'HARD delete|soft' "${REPO}/ai-agent.sh"; then
  ok "help text shows both soft and hard modes"
else
  nok "help text missing mode description"
fi

# 24b: tool manifest exists with run.script
if grep -q '"name": "task_clear"' "${REPO}/tools/task_clear.json" && \
   grep -q '"script": "task_clear.sh"' "${REPO}/tools/task_clear.json"; then
  ok "task_clear.json manifest valid"
else
  nok "task_clear.json manifest missing run.script"
fi

# 24c: tool script exists and is executable
[[ -x "${REPO}/tools/task_clear.sh" ]] && ok "task_clear.sh exists and is executable" || nok "task_clear.sh missing or not executable"

# === SOFT MODE (no -y) ===
seed_t24_db "$T24_DB"

# 24d: /task clear (bare) flips pending → cancelled, keeps done
out=$(echo -e "/task clear\nexit" | AI_AGENT_DB="$T24_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "cancelled 2" | head -1)
[[ -n "$out" ]] && ok "/task clear (soft) reports cancelled=2" || nok "/task clear (soft) wrong: $out"

# 24e: goal preserved (the key difference from /team clear)
goal=$(sqlite3 "$T24_DB" "SELECT value FROM team_state WHERE key='current_goal';" 2>/dev/null)
[[ "$goal" == "keep me" ]] && ok "goal preserved after soft /task clear" || nok "goal NOT preserved: '$goal'"

# 24f: tasks state — 0 pending, 1 done, 2 cancelled (the 2 pending were flipped)
canc_n=$(sqlite3 "$T24_DB" "SELECT COUNT(*) FROM tasks WHERE status='cancelled';" 2>/dev/null)
done_n=$(sqlite3 "$T24_DB" "SELECT COUNT(*) FROM tasks WHERE status='done';" 2>/dev/null)
[[ "$canc_n" == "2" && "$done_n" == "1" ]] && ok "soft: rows preserved (2 cancelled, 1 done)" || nok "soft: wrong state cancelled=$canc_n done=$done_n"

# 24g: events preserved in soft mode (audit trail intact)
# Note: each task gets 2 events (1 from task_create.sh, 1 from the seed INSERT),
# so 3 tasks at seed time = 6 events; soft must preserve all 6.
ev_n=$(sqlite3 "$T24_DB" "SELECT COUNT(*) FROM task_events;" 2>/dev/null)
[[ "$ev_n" == "6" ]] && ok "soft: all 6 events preserved (audit intact)" || nok "soft: events wrong: $ev_n (expected 6)"

# === HARD MODE (-y) — FULL WIPE (deletes ALL tasks incl. done) ===
seed_t24_db "$T24_DB"

# 24h: /task clear -y wipes ALL tasks + their events
out=$(echo -e "/task clear -y\nexit" | AI_AGENT_DB="$T24_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -E "^.*FULL WIPE: deleted 3 task\(s\) \+ [0-9]+ event\(s\)" | head -1)
[[ -n "$out" ]] && ok "/task clear -y (hard) reports FULL WIPE 3 + events" || nok "/task clear -y wrong: $out"

# 24i: goal STILL preserved in hard mode (only /team clear touches goal)
goal=$(sqlite3 "$T24_DB" "SELECT value FROM team_state WHERE key='current_goal';" 2>/dev/null)
[[ "$goal" == "keep me" ]] && ok "goal preserved after hard /task clear" || nok "hard: goal NOT preserved: '$goal'"

# 24j: tasks table is EMPTY (incl. the previously done task)
total=$(sqlite3 "$T24_DB" "SELECT COUNT(*) FROM tasks;" 2>/dev/null)
[[ "$total" == "0" ]] && ok "hard: tasks table is empty (full wipe)" || nok "hard: tasks remaining: $total"

# 24k: ALL events are gone (including the done task's)
ev_n=$(sqlite3 "$T24_DB" "SELECT COUNT(*) FROM task_events;" 2>/dev/null)
[[ "$ev_n" == "0" ]] && ok "hard: all events deleted (full audit wipe)" || nok "hard: events remaining: $ev_n"

# === EDGE CASES ===
seed_t24_db "$T24_DB"
sqlite3 "$T24_DB" "UPDATE tasks SET status='cancelled' WHERE title IN ('p1','p2');"  # only d1 is done

# 24l: /task clear on no-pending is idempotent (says "nothing to soft-cancel")
out=$(echo -e "/task clear\nexit" | AI_AGENT_DB="$T24_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "nothing to soft-cancel" | head -1)
[[ -n "$out" ]] && ok "soft: idempotent (no pending)" || nok "soft: $out"

# 24m: /task clear -y ALWAYS wipes (even if all tasks are already done/cancelled)
out=$(echo -e "/task clear -y\nexit" | AI_AGENT_DB="$T24_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "FULL WIPE: deleted 3" | head -1)
[[ -n "$out" ]] && ok "hard: wipes even when nothing is pending" || nok "hard: $out"

# 24n: /task clear foo → usage
out=$(echo -e "/task clear foo\nexit" | AI_AGENT_DB="$T24_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "usage: /task clear [-y|--yes]" | head -1)
[[ -n "$out" ]] && ok "/task clear bogus shows usage" || nok "bogus: $out"

# 24o: /task clear --yes also triggers hard mode
seed_t24_db "$T24_DB"
out=$(echo -e "/task clear --yes\nexit" | AI_AGENT_DB="$T24_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -E "^.*FULL WIPE: deleted 3 task\(s\)" | head -1)
[[ -n "$out" ]] && ok "/task clear --yes triggers hard mode" || nok "--yes: $out"

# 24p: tool task_clear.sh soft mode (bypass REPL) — direct invocation
seed_t24_db "$T24_DB"
direct=$(AI_AGENT_DB="$T24_DB" sh "${REPO}/tools/task_clear.sh" '{}')
mode=$(echo "$direct" | jq -r '.mode')
deleted=$(echo "$direct" | jq -r '.deleted')
[[ "$mode" == "soft" && "$deleted" == "2" ]] && ok "tool soft: mode=soft deleted=2 (2 pending)" || nok "tool soft: $direct"

# 24q: tool task_clear.sh hard mode (direct) — wipes all
seed_t24_db "$T24_DB"
direct=$(AI_AGENT_DB="$T24_DB" sh "${REPO}/tools/task_clear.sh" '{"yes":true}')
mode=$(echo "$direct" | jq -r '.mode')
deleted=$(echo "$direct" | jq -r '.deleted')
ev=$(echo "$direct" | jq -r '.events_deleted')
[[ "$mode" == "hard" && "$deleted" == "3" && "$ev" -ge 3 ]] && ok "tool hard: mode=hard deleted=3 events>=$ev" || nok "tool hard: $direct"

# 24r: hard wipe is truly destructive — re-running soft after hard finds nothing
out=$(AI_AGENT_DB="$T24_DB" sh "${REPO}/tools/task_clear.sh" '{}')
deleted=$(echo "$out" | jq -r '.deleted')
[[ "$deleted" == "0" ]] && ok "after hard wipe, soft finds 0" || nok "soft after hard: $out"

rm -f "$T24_DB"

hr "Test 25: /board subcommands (write / reply / clear / topics / grep / stat / since / -n / <id>)"

# Helper: seed a blackboard with a known mix
seed_t25_bb() {
    local db="$1"
    rm -f "$db"
    sqlite3 "$db" "CREATE TABLE IF NOT EXISTS board (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL DEFAULT '', topic TEXT NOT NULL, payload TEXT NOT NULL, reply_to INTEGER, created_at TEXT DEFAULT (datetime('now'))); CREATE INDEX IF NOT EXISTS idx_board_topic ON board(topic);" 2>/dev/null
    AI_AGENT_DB="$db" AGENT_NAME="alice" sh "${REPO}/tools/board_write.sh" '{"topic":"plan","payload":"step 1"}' >/dev/null
    AI_AGENT_DB="$db" AGENT_NAME="alice" sh "${REPO}/tools/board_write.sh" '{"topic":"plan","payload":"step 2 — see also review notes"}' >/dev/null
    AI_AGENT_DB="$db" AGENT_NAME="bob"   sh "${REPO}/tools/board_write.sh" '{"topic":"review","payload":"looks ok"}' >/dev/null
}

T25_DB=/tmp/ai-agent-test-25-$$.db
seed_t25_bb "$T25_DB"

# 25a: help text mentions the new subcommands
if grep -qE '/board write' "${REPO}/ai-agent.sh" && \
   grep -qE '/board reply' "${REPO}/ai-agent.sh" && \
   grep -qE '/board clear' "${REPO}/ai-agent.sh" && \
   grep -qE '/board topics' "${REPO}/ai-agent.sh" && \
   grep -qE '/board grep' "${REPO}/ai-agent.sh" && \
   grep -qE '/board stat' "${REPO}/ai-agent.sh"; then
  ok "help text shows all 6 new subcommands"
else
  nok "help text missing some subcommand"
fi

# 25b: /board (no arg) shows topic summary table
out=$(echo -e "/board\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -E "^plan\b" | head -1)
[[ -n "$out" ]] && ok "/board (no arg) shows topic summary" || nok "/board summary missing: $out"

# 25c: /board write <topic> <payload> inserts a new entry
out=$(echo -e "/board write plan step 3\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "board write ok" | head -1)
[[ -n "$out" ]] && ok "/board write reports success" || nok "/board write failed: $out"
n=$(sqlite3 "$T25_DB" "SELECT COUNT(*) FROM board WHERE topic='plan'")
[[ "$n" == "3" ]] && ok "/board write inserted 1 entry (3 total in plan)" || nok "/board write: expected 3 in 'plan', got $n"

# 25d: /board write with no payload shows usage
out=$(echo -e "/board write plan\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "usage: /board write" | head -1)
[[ -n "$out" ]] && ok "/board write (no payload) shows usage" || nok "/board write no-payload: $out"

# 25e: /board reply <id> <payload> creates a reply in the same topic
out=$(echo -e "/board reply 1 ack from tester\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "board reply ok" | head -1)
[[ -n "$out" ]] && ok "/board reply reports success" || nok "/board reply failed: $out"
n=$(sqlite3 "$T25_DB" "SELECT COUNT(*) FROM board WHERE reply_to=1")
[[ "$n" == "1" ]] && ok "/board reply set reply_to=1" || nok "/board reply: expected 1 reply_to=1, got $n"

# 25f: /board <topic> lists entries (existing 80-char behavior)
out=$(echo -e "/board plan\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "step 1" | head -1)
[[ -n "$out" ]] && ok "/board <topic> lists entries" || nok "/board <topic>: $out"

# 25g: /board <topic> <id> shows full payload of one entry
out=$(echo -e "/board plan 2\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "review notes" | head -1)
[[ -n "$out" ]] && ok "/board <topic> <id> shows full payload" || nok "/board single id: $out"

# 25h: /board <topic> --since <id> filters
out=$(echo -e "/board plan --since 1\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "step 1" | head -1)
[[ -z "$out" ]] && ok "/board plan --since 1 hides id=1" || nok "--since 1 leaked: $out"
n=$(echo -e "/board plan --since 1\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -cE '^\[2\]|^\[3\]|^\[4\]|^\[5\]')
[[ "$n" -ge 1 ]] && ok "/board plan --since 1 shows entries with id>1" || nok "--since 1: expected >=1 entry, got $n"

# 25i: /board <topic> -n <N> limits
out=$(echo -e "/board plan -n 1\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -cE '^\[[0-9]+\]')
[[ "$out" == "1" ]] && ok "/board plan -n 1 returns exactly 1 entry" || nok "/board -n 1: expected 1, got $out"

# 25j: /board topics [prefix] uses the board_list tool
out=$(echo -e "/board topics\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "plan" | head -1)
[[ -n "$out" ]] && ok "/board topics lists distinct topics" || nok "/board topics: $out"
out=$(echo -e "/board topics rev\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "review" | head -1)
[[ -n "$out" ]] && ok "/board topics rev filters by prefix" || nok "/board topics rev: $out"

# 25k: /board grep <pattern> searches payloads across all topics
out=$(echo -e "/board grep step\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "step 1" | head -1)
[[ -n "$out" ]] && ok "/board grep step finds matching entries" || nok "/board grep: $out"
out=$(echo -e "/board grep nonexistent_pattern_xyz\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "no matches" | head -1)
[[ -n "$out" ]] && ok "/board grep no-match shows 'no matches'" || nok "/board grep no-match: $out"

# 25l: /board stat shows totals
out=$(echo -e "/board stat\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "total entries" | head -1)
[[ -n "$out" ]] && ok "/board stat shows totals" || nok "/board stat: $out"
out=$(echo -e "/board stat\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "alice" | head -1)
[[ -n "$out" ]] && ok "/board stat breaks down by agent" || nok "/board stat by-agent: $out"

# 25m: /board clear <topic> (soft) renames the topic
seed_t25_bb "$T25_DB"
out=$(echo -e "/board clear plan\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "board clear ok: mode=soft" | head -1)
[[ -n "$out" ]] && ok "/board clear soft reports success" || nok "/board clear soft: $out"
n=$(sqlite3 "$T25_DB" "SELECT COUNT(*) FROM board WHERE topic='[cleared] plan'")
[[ "$n" == "2" ]] && ok "soft clear renamed 2 rows to '[cleared] plan'" || nok "soft clear: expected 2 in '[cleared] plan', got $n"

# 25n: /board clear <topic> -y (hard) DELETEs the rows
seed_t25_bb "$T25_DB"
out=$(echo -e "/board clear plan -y\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "board clear ok: mode=hard" | head -1)
[[ -n "$out" ]] && ok "/board clear -y reports hard success" || nok "/board clear -y: $out"
n=$(sqlite3 "$T25_DB" "SELECT COUNT(*) FROM board WHERE topic='plan'")
[[ "$n" == "0" ]] && ok "hard clear deleted all 2 'plan' rows" || nok "hard clear: expected 0 'plan', got $n"

# 25o: /board clear with bogus arg shows usage
out=$(echo -e "/board clear plan foo\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "usage: /board clear" | head -1)
[[ -n "$out" ]] && ok "/board clear bogus shows usage" || nok "/board clear bogus: $out"

# 25p: /board clear is idempotent (running again finds 0)
seed_t25_bb "$T25_DB"
echo -e "/board clear plan -y\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" >/dev/null 2>&1
out=$(echo -e "/board clear plan\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -F "no entries for topic" | head -1)
[[ -n "$out" ]] && ok "/board clear (no entries) shows 'no entries'" || nok "/board clear idempotent: $out"

# 25q: tool board_clear.sh — direct soft invocation
seed_t25_bb "$T25_DB"
direct=$(AI_AGENT_DB="$T25_DB" sh "${REPO}/tools/board_clear.sh" '{"topic":"plan"}')
mode=$(echo "$direct" | jq -r '.mode')
affected=$(echo "$direct" | jq -r '.affected')
[[ "$mode" == "soft" && "$affected" == "2" ]] && ok "tool soft: mode=soft affected=2" || nok "tool soft: $direct"

# 25r: tool board_clear.sh — direct hard invocation
seed_t25_bb "$T25_DB"
direct=$(AI_AGENT_DB="$T25_DB" sh "${REPO}/tools/board_clear.sh" '{"topic":"review","yes":true}')
mode=$(echo "$direct" | jq -r '.mode')
deleted=$(echo "$direct" | jq -r '.deleted')
[[ "$mode" == "hard" && "$deleted" == "1" ]] && ok "tool hard: mode=hard deleted=1" || nok "tool hard: $direct"

# 25s: tool board_write.sh now returns success:true
seed_t25_bb "$T25_DB"
direct=$(AI_AGENT_DB="$T25_DB" AGENT_NAME="carol" sh "${REPO}/tools/board_write.sh" '{"topic":"x","payload":"y"}')
success=$(echo "$direct" | jq -r '.success')
id=$(echo "$direct" | jq -r '.id')
[[ "$success" == "true" && -n "$id" && "$id" != "null" ]] && ok "tool board_write returns success:true + id" || nok "tool board_write: $direct"

# 25t: --since and -n can be combined
seed_t25_bb "$T25_DB"
out=$(echo -e "/board plan --since 1 -n 1\nexit" | AI_AGENT_DB="$T25_DB" timeout 10 bash "${REPO}/ai-agent.sh" 2>&1 | grep -cE '^\[[0-9]+\]')
[[ "$out" == "1" ]] && ok "/board plan --since 1 -n 1 returns 1 entry" || nok "combined opts: expected 1, got $out"

rm -f "$T25_DB"

hr "Test 26: TAB completion (lib/complete.sh)"

# Helper: simulate a TAB press in the REPL by sourcing lib/complete.sh
# (which binds \C-i to _ai_complete), then setting READLINE_LINE/POINT
# and calling _ai_complete. The function may either mutate
# READLINE_LINE (single/multi candidate with extension) or print
# candidates to stderr (multi candidate with no extension). We test
# both modes.
simulate_tab() {
    # args: initial_line [point]
    local line="$1" point="${2:-${#1}}"
    (
        # Subshell so the in-process state doesn't leak
        # shellcheck disable=SC1090
        . "${REPO}/lib/complete.sh"
        READLINE_LINE="$line"
        READLINE_POINT="$point"
        # Capture stderr (candidate listing) and the final READLINE state
        exec 3>&2
        _ai_complete 2>/tmp/ai-tab-stderr.$$
        local out_line="$READLINE_LINE"
        local out_point="$READLINE_POINT"
        exec 2>&3
        # Use a delimiter that never appears in the line: |@|
        printf '|@|LINE|%s|%d|ENDLINE|@|\n' "$out_line" "$out_point"
        if [[ -s /tmp/ai-tab-stderr.$$ ]]; then
            printf '|@|CANDIDATES|@|\n'
            cat /tmp/ai-tab-stderr.$$
            printf '|@|ENDCANDS|@|\n'
        fi
        rm -f /tmp/ai-tab-stderr.$$
    )
}

# Helper: extract a tagged field from simulate_tab output.
# usage: extract_field "tagname" "$output"
extract_field() {
    local tag="$1" out="$2"
    # Match "|@|TAG|...|ENDTAG|" or "|@|TAG|something|ENDTAG|"
    # First try the "line" form with point suffix
    if [[ "$tag" == "LINE" ]]; then
        printf '%s' "$out" | sed -n 's/.*|@|LINE|\(.*\)|[0-9]*|ENDLINE|@|.*/\1/p'
    elif [[ "$tag" == "POINT" ]]; then
        printf '%s' "$out" | sed -n 's/.*|@|LINE|.*|\([0-9]*\)|ENDLINE|@|.*/\1/p'
    elif [[ "$tag" == "CANDIDATES" ]]; then
        # Multi-line: extract between CANDIDATES and ENDCANDS markers
        printf '%s' "$out" | awk '
            /\|@\|CANDIDATES\|@\|/ {f=1; next}
            /\|@\|ENDCANDS\|@\|/ {f=0}
            f
        '
    fi
}

# 26a: lib/complete.sh exists and is sourced by ai-agent.sh
[[ -f "${REPO}/lib/complete.sh" ]] && ok "lib/complete.sh exists" || nok "lib/complete.sh missing"
if grep -q 'lib/complete.sh' "${REPO}/ai-agent.sh"; then
    ok "ai-agent.sh sources lib/complete.sh"
else
    nok "ai-agent.sh does not source lib/complete.sh"
fi

# 26b: TAB handler is bound to \C-i
if grep -qE 'bind -x.*_ai_complete' "${REPO}/lib/complete.sh"; then
    ok "TAB bound to _ai_complete via bind -x"
else
    nok "no bind -x for _ai_complete"
fi

# 26c: /age → /agent (single-cmd completion)
out=$(simulate_tab "/age")
got_line=$(extract_field LINE "$out")
got_point=$(extract_field POINT "$out")
if [[ "$got_line" == "/agent" ]] && [[ "$got_point" == "6" ]]; then
    ok "/age completes to /agent"
else
    nok "/age did not complete: line=[$got_line] point=[$got_point]"
fi

# 26d: /b → /board (extend to LCP of /board*)
out=$(simulate_tab "/b")
got_line=$(extract_field LINE "$out")
got_point=$(extract_field POINT "$out")
if [[ "$got_line" == "/board" ]] && [[ "$got_point" == "6" ]]; then
    ok "/b extends to /board"
else
    nok "/b did not extend: line=[$got_line] point=[$got_point]"
fi

# 26e: /agent (already a complete command) lists candidates
out=$(simulate_tab "/agent")
cands=$(extract_field CANDIDATES "$out")
if [[ -n "$cands" && "$cands" == *"/agent reload"* && "$cands" == *"/agents"* ]]; then
    ok "/agent lists /agent reload + /agents as candidates"
else
    nok "/agent did not list: [$cands]"
fi

# 26f: /board + space → lists subcommands (write, reply, ...)
out=$(simulate_tab "/board " 7)
cands=$(extract_field CANDIDATES "$out")
if [[ -n "$cands" && "$cands" == *"write"* && "$cands" == *"reply"* && "$cands" == *"clear"* ]]; then
    ok "/board (with space) lists subcommands"
else
    nok "/board (space) did not list: [$cands]"
fi

# 26g: /board w → /board write (single subcommand)
out=$(simulate_tab "/board w")
got_line=$(extract_field LINE "$out")
got_point=$(extract_field POINT "$out")
if [[ "$got_line" == "/board write" ]] && [[ "$got_point" == "12" ]]; then
    ok "/board w completes to /board write"
else
    nok "/board w did not complete: line=[$got_line] point=[$got_point]"
fi

# 26h: /board cle → /board clear (single subcommand match)
out=$(simulate_tab "/board cle")
got_line=$(extract_field LINE "$out")
got_point=$(extract_field POINT "$out")
if [[ "$got_line" == "/board clear" ]] && [[ "$got_point" == "12" ]]; then
    ok "/board cle completes to /board clear"
else
    nok "/board cle did not complete: line=[$got_line] point=[$got_point]"
fi

# 26i: /task clear - → lists -y and --yes
out=$(simulate_tab "/task clear -" 12)
cands=$(extract_field CANDIDATES "$out")
if [[ -n "$cands" && "$cands" == *"-y"* && "$cands" == *"--yes"* ]]; then
    ok "/task clear - lists -y/--yes flags"
else
    nok "/task clear - did not list flags: [$cands]"
fi

# 26j: /xyz → no change (no candidates)
out=$(simulate_tab "/xyz")
got_line=$(extract_field LINE "$out")
got_point=$(extract_field POINT "$out")
cands=$(extract_field CANDIDATES "$out")
if [[ "$got_line" == "/xyz" ]] && [[ "$got_point" == "4" ]] && [[ -z "$cands" ]]; then
    ok "/xyz (no match) leaves line unchanged"
else
    nok "/xyz behavior wrong: line=[$got_line] cands=[$cands]"
fi

# 26k: hello (non-/command) → no change
out=$(simulate_tab "hello")
got_line=$(extract_field LINE "$out")
got_point=$(extract_field POINT "$out")
cands=$(extract_field CANDIDATES "$out")
if [[ "$got_line" == "hello" ]] && [[ "$got_point" == "5" ]] && [[ -z "$cands" ]]; then
    ok "hello (non-/command) leaves line unchanged"
else
    nok "hello behavior wrong: line=[$got_line] cands=[$cands]"
fi

# 26l: empty line → lists all commands
out=$(simulate_tab "" 0)
cands=$(extract_field CANDIDATES "$out")
if [[ -n "$cands" && "$cands" == *"/board"* && "$cands" == *"/task"* && "$cands" == *"/team"* ]]; then
    ok "empty line lists all commands"
else
    nok "empty line did not list: [$cands]"
fi

# 26m: /team (parent command itself) → list /team* candidates
out=$(simulate_tab "/team")
cands=$(extract_field CANDIDATES "$out")
if [[ -n "$cands" && "$cands" == *"/team start"* && "$cands" == *"/team clear"* ]]; then
    ok "/team lists subcommands (start, clear, etc.)"
else
    nok "/team did not list: [$cands]"
fi

# 26n: regex meta-chars in current are escaped (no false matches / no crash)
out=$(simulate_tab "/.\\")
cands=$(extract_field CANDIDATES "$out")
# /. is not a known command, so we expect no line change AND no candidates.
# This proves the regex meta-char `\.` was escaped (no grep crash, no injection).
got_line=$(extract_field LINE "$out")
if [[ "$got_line" == "/.\\" ]] && [[ -z "$cands" ]]; then
    ok "regex meta-chars in /pattern handled safely (no crash, no match)"
else
    nok "regex meta-chars: line=[$got_line] cands=[$cands]"
fi

# 26o: /board + space with cursor at end-of-parent (cursor-mid scenario)
out=$(simulate_tab "/board " 6)
# At pt=6, prefix=/board, current="" (cursor right after the parent)
cands=$(extract_field CANDIDATES "$out")
if [[ -n "$cands" && "$cands" == *"write"* && "$cands" == *"reply"* ]]; then
    ok "cursor at end of /board lists subcommands"
else
    nok "cursor-mid: [$cands]"
fi

hr "Summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
