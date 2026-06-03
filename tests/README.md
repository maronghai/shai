# tests/

Test suite for `ai-agent.sh`. **21 test groups, 96 sub-assertions.** Run
from the repo root (or any directory — paths are repo-relative):

```bash
bash tests/test.sh
# or
./tests/test.sh
```

Output ends with:

```
=== Summary ===
  PASS: <N>
  FAIL: <N>
ALL TESTS PASSED            # exit 0
SOME TESTS FAILED           # exit 1
```

## What it covers

| # | Group | What it checks |
|---|---|---|
| 1  | `agent_list` | default agent + 7 personas, description from frontmatter |
| 2  | `code-reviewer` `exec_command` override | returns `success:false` with "disabled" in error |
| 3  | Blackboard roundtrip | write → reply_to chain → read since_id → list topics |
| 4  | `load_tools` merge | dedupes by `function.name` with last-wins (agent overrides base) |
| 5  | `agent_delegate` rejects `default` | refuses to delegate to system "default" agent |
| 6  | `agent_delegate` rejects unknown | refuses non-existent agent name |
| 7  | `agent_delegate` refuses deep recursion | `DELEGATION_DEPTH>=2` is rejected |
| 8  | `agent_delegate` rejects oversize task | task body cap (100 KB) |
| 9  | `agent_delegate` name regex | rejects `../etc/passwd` and similar injection attempts |
| 10 | Tool manifest JSON | every `tools/*.json` and `agents/*/tools/*.json` parses |
| 11 | Script syntax | every `.sh` script and `ai-agent.sh` passes `bash -n` |
| 12 | Persona descriptions | every `agents/*/system.md` has frontmatter description or H1 |
| 13 | `agent_status` line format | contains `name=%s db=%s msgs=%s tools=%s` placeholders |
| 14 | Frontmatter helpers + `/agents @tag` | `parse_frontmatter` / `agent_description` / `agent_tags` defined; tag filter wired |
| 15 | `/hist full <id>` | block renderer supports per-id and full mode |
| 16 | `/agents` numbered + `/agent <id>` | `_resolve_agent_id` defined; `/agent 1` switches to default; out-of-range errors |
| 17 | REPL prompt shows agent info | `_agent_prompt` emits real ESC bytes; default / code-reviewer / coordinator prompts format correctly; long descriptions truncated to 30 chars |
| 18 | `/tasks` and `/task` | REPL cases wired; `task_show` tool defined |
| 19 | 6 personas (pm/architect/developer/tester/docs + code-reviewer + coordinator) | each has `system.md`; `/agent` switches to each; `/agents @design` filter works |
| 20 | `/team` workflow | `team_state` table defined; 5 `_team_*` functions defined; type→agent mapping (pm/architect/developer/code-reviewer/tester/docs/coordinator) correct |
| 21 | `/team clear` soft-cancels | flips non-done tasks to `cancelled`; preserves `done` rows; clears `current_goal`; idempotent; `-y` / `--yes` skip prompt; unknown flag → usage hint |

## What it does NOT cover

The suite is **LLM-free** — it tests script structure, tool plumbing, REPL
dispatch, and database roundtrips. It does NOT exercise the actual ReAct
loop with a real model response. End-to-end demos with a live `BASE_URL`
are documented in [book.md §14.9](../book.md#149-端到端-demo-跟踪).

## Requirements

- `bash` 4.0+
- `sqlite3` (json1 ext)
- `jq`
- `sed`, `awk`, `xxd`, `mktemp` (standard on Linux/macOS)
- `timeout` (GNU coreutils)

## Writing new tests

Append another `hr "Test N: ..."` block. Reuse the helpers:

```bash
hr "Test N: short description"   # header
ok  "pass message"               # green PASS
nok "fail message"               # red FAIL
```

The summary at the end automatically counts; just call `ok` / `nok`.
