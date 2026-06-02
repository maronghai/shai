# Changelog

All notable changes to **ai-agent.sh** are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-06-02

### Fixed
- **`load_tools` silently produced empty `tool_descriptions`.** The v0.1.0 rewrite
  passed the whole tool array `$tools_json` to a jq filter that expected a
  single object. jq exited 5 with `Cannot index array with string "function"`
  to stderr (suppressed by `2>/dev/null`), and the script's main loop then
  hit the EOF branch and exited cleanly with no output. Fix: prepend `.[] |`
  to the filter so it iterates per tool.
- **`/board` was treated as topic `/board`.** The case branch `/board*` ran
  `${input#/board }`, which strips `/board ` (with trailing space) — but
  the bare command `/board` has no trailing space, so the prefix wasn't
  stripped and `/board` was queried as a topic key. Fix: split into
  exact-match `/board` (list topics) and `/board\ *` (with-arg).
- **`code-reviewer/tools/exec_command.json` lacked `run.script`.** The
  agent override JSON only declared `function.{name, description}`,
  missing the `run` block — so `_load_one_tool` rejected it with
  `Skipping tool 'exec_command': run.script missing`. Fix: add the `run`
  block pointing to the disabled `exec_command.sh` stub.
- **`code-reviewer/tools/exec_command.json` lacked `function.parameters`.**
  The override manifest only declared `function.{name, description}`, so
  when `group_by | map(last)` merged it over the base, the resulting
  `exec_command` had `parameters: null` in the request body. The MiniMax
  provider rejected it with `invalid params, function name or parameters
  is empty (2013)`. Fix: declare a `parameters` schema (mirroring the
  base) in the override. The model still sees the disabled description
  and the runtime stub still refuses, so the security boundary is
  preserved — the fix is purely about request validation.

### Added
- **Multi-agent support.** Named agent personas in `agents/<name>/system.md`,
  each with its own SQLite history (`.data/chat_<name>.db`), tool set
  (`agents/<name>/tools/`), and recoverable current-agent state
  (`.data/.current_agent`).
  - `/agent` — one-line status: `current=<name> db=<path> msgs=<N> tools=<N>`
  - `/agent <name>` — switch to a named agent (or `default`)
  - `/agent reload` — reload current agent's prompt and tools
  - `/agents` — list all available agents (current marked `*`)
  - Root `SYSTEM_PROMPT.md` is **not** migrated: the default (no agent
    selected) context still uses it and `.data/chat.db`, so existing v0.0.6
    setups are unaffected.
- **Blackboard** for inter-agent communication (`.data/blackboard.db`):
  - `board_write(topic, payload, reply_to?)` → new id
  - `board_read(topic, since_id?, limit?)` → JSON array of rows
  - `board_list(prefix?)` → distinct topic list
  - `/board [topic]` command for human inspection
- **Agent delegation** tool `agent_delegate(agent, task, topic?)`:
  - Spawns `ai-agent.sh` with `NON_INTERACTIVE=1`, fresh agent context
  - Hard-removes `exec_command` and `agent_delegate` from the sub-agent's
    tool set (defense in depth, not just prompt-guidance)
  - Caps inner ReAct iterations at 5 (`MAX_NON_INTERACTIVE_ITERS`)
  - Caps recursion depth at 2 (`DELEGATION_DEPTH`); depth ≥ 2 also injects
    an explicit "do not delegate further" instruction into the system prompt
  - Sub-agent's final reply is written to the blackboard with
    `reply_to=<parent_id>` and returned to the caller (truncated to 8000 chars)
  - 120s wall-clock timeout, 90s of which spent waiting for the reply
- **`agent_list` tool** — returns a JSON array of `{name, description}` for
  default + all named agents; useful for orchestrator personas.
- **`/board` command** for human-friendly inspection of the blackboard
  (lists all topics with counts, or rows for a given topic).
- **`/hist full` and `/hist <id>` subcommands.** The summary `/hist` now
  has two new modes: `/hist full` dumps every message with its complete
  `content` / `raw_input` / `thinking` and every associated `tool_call`
  (with full `arguments` and `result`, no length truncation), and
  `/hist <id>` prints a single message by id together with its tool
  calls. Unknown ids print `no message with id=N` and continue.
- **`/hist full <id>` subcommand.** Combines the two previous modes:
  renders a single message in the `_hist_full` style (block header with
  role + `has_tool_calls`, full `content` / `raw_input` / `thinking`,
  and all associated `tool_call` blocks) instead of the slimmer
  `_hist_one` style. Non-numeric ids print `id must be numeric`; missing
  ids print `no message with id=N` and the REPL continues.
- **YAML-ish frontmatter in `agents/<name>/system.md`.** A `---`-fenced
  block at the top of an agent's `system.md` can declare
  `description: <short text>` and `tags: <csv>`. `list_agents` shows
  the description (instead of the first H1 line) and appends a
  `[tag1, tag2]` column. `agent_status` prints `name` / `description` /
  `tags` / `db` / `msgs` / `tools`. `tools/agent_list.sh` exposes
  `description` and `tags` to sub-agents (the LLM-facing tool). The
  H1 line is still the fallback if frontmatter is absent, so existing
  agents keep working.
- **`/agents @tag` filter.** New subcommand `/agents @<tag>` lists only
  agents whose `tags` CSV contains that tag. `no agents match tag @x`
  is printed if nothing matches; `/agents @` (empty) prints the usage.
- **Numbered `/agents` and `/agent <id>`.** `/agents` now prints a
  1-based index in front of each row (default = 1, then named agents
  in directory order). The numbers stay stable across tag filters (so
  `/agent 2` always means the second slot, regardless of which `/agents
  @tag` you used to find it). `/agent <N>` resolves the number via the
  new `_resolve_agent_id` helper and then calls the existing
  `switch_agent`. Out-of-range numbers print `no agent with id N
  (try /agents to list)`; the name form is unchanged.
- **Tool namespace merge in `load_tools`.** When a named agent is active, the
  agent's `agents/<name>/tools/*.json` is loaded *after* the base
  `tools/*.json`, and the merge dedupes by `function.name` with last-wins
  semantics — so an agent can override a base tool (e.g. disable
  `exec_command`) by re-declaring it under its own `tools/`.
- **Pre-built personas**:
  - `agents/coordinator/system.md` — orchestrator that uses `agent_list` +
    `agent_delegate` + blackboard to break tasks into sub-tasks.
  - `agents/code-reviewer/system.md` + `agents/code-reviewer/tools/exec_command.{json,sh}`
    — read-only review persona; the local override makes `exec_command`
    return `{"success":false,"error":"exec_command is disabled in this agent (read-only review mode)"}`.
- **`db_quote` / `bb_quote` helpers** — consistent SQL string escaping for
  the chat DB and the blackboard DB. The `bb_*` family wraps
  `.data/blackboard.db`; the chat helpers (already present) are unchanged.
- **Tool runtime env injection.** `run_tool` now passes `AGENT_NAME`,
  `BLACKBOARD_DB_PATH`, `WORK_DIR`, `AGENTS_DIR`, and `DELEGATION_DEPTH` to
  the tool subprocess so `agent_delegate.sh` and `agent_list.sh` can find
  the main script, the blackboard, and the agents/ directory without
  re-deriving them.

### Changed
- **Per-agent cache files.** `tools_cache.json` and `tools_desc.txt` are now
  suffixed with the agent name (`tools_cache_<name>.json`,
  `tools_desc_<name>.txt`) when a named agent is active, and the cache
  invalidation check now also looks at `agents/<name>/tools/*.json` mtimes.
  The default-agent paths (no suffix) are unchanged, so the on-disk layout
  for an unswitched install is identical to v0.0.6.
- **`DB_PATH` is no longer a single hardcoded constant.** It is computed
  from the new `db_path()` function, which returns `chat.db` for the
  default context and `chat_<name>.db` for named agents. All call sites
  still use `$DB_PATH`, so the change is internal.
- **Restored agent name on startup.** If `.data/.current_agent` is set and
  the referenced `agents/<name>/system.md` still exists, the script
  resumes in that agent context; otherwise it falls back to default. The
  candidate is regex-validated (`^[a-zA-Z0-9_-]+$`) to refuse injection
  via the marker file.

## [Unreleased]

### Added
- **`messages.thinking` column** (TEXT, nullable) for storing `<think>...</think>`
  blocks from reasoning models (DeepSeek R1, etc.). The thinking is shown
  to the user locally (dim "think: …" line above the answer, as before) and
  persisted in the DB for `/hist` inspection — but is **never loaded back
  into the conversation history** (`load_history` doesn't select it). This
  saves tokens on subsequent turns (the model doesn't re-read its own past
  reasoning) while keeping the trace locally.
  - `add_message` takes a 4th `thinking` arg; `save_assistant_tool_call`
    takes a 3rd `thinking` arg.
  - Thinking is extracted from both the final-response path and the
    tool-call path (when an assistant message has reasoning before
    calling tools).
  - `/hist` now shows the `thinking` length per row.
  - `init_db` migrates: detects missing `thinking` column on `messages`
    and drops both tables, recreating with the new schema.
- `<think>...</think>` blocks in model replies are surfaced as a
  `think: <content>` line above the answer (e.g. DeepSeek R1, reasoning models).
  The label is **bold cyan** (`\033[1;36m`), the content is **gray**
  (`\033[90m` = `DM` in the color table) — uses the ANSI "bright black"
  slot which renders as a light-medium gray on every terminal, clearly
  readable on a black background but visually subordinate to the default
  white body text. Body text stays in the default terminal color for
  max readability. Stripped from the saved message so the conversation log
  stays clean.
  - **Shown in BOTH paths:** final-response (`finish_reason == "stop"`)
    and tool-call (`finish_reason == "tool_calls"`). Previously the
    tool-call path only saved the think to the DB and never echoed it
    to the terminal, so users never saw the model's reasoning when it
    decided to invoke a tool.
  - **Always shown, with placeholder when empty.** The reasoning model
    in use (`MiniMax-M3`) inconsistently emits `<think>...</think>`
    blocks — same prompt sometimes gets reasoning, sometimes plain text.
    The script now always prints a `think:` line, defaulting to
    `(no reasoning)` when the model skipped the think block. The DB
    still only stores real thinking (NULL when absent) so `/hist`
    stays honest about which turns actually had reasoning.

### Fixed
- **`load_history` leaked orphan `tool_calls` into the request,**
  causing API errors like
  `tool result's tool id(call_function_xxx) not found (2013)`.
  The CTE's second branch was `SELECT ... FROM tool_calls tc` with
  no JOIN or WHERE, so rows referencing deleted `messages` (orphans
  left over from earlier FK=OFF operations) were still emitted as
  `role:'tool'` messages with a `tool_call_id` the model never
  requested. Fixed by adding `INNER JOIN messages m2 ON m2.id = tc.message_id`,
  which filters orphans at read time. The `messages` side already
  used `m.id` directly, so no change needed there.
- **`/clear` left orphan rows in `tool_calls`.** The handler called
  `sqlite3 "$DB_PATH" "DELETE FROM messages"` directly, which opens
  a fresh connection without `PRAGMA foreign_keys=ON`, so
  `ON DELETE CASCADE` on `tool_calls.message_id` never fired.
  Switched to the `sql` helper, which sets the pragma.
- **`db_quote` was silently corrupting single quotes in stored content.**
  The original pattern `${var//\'/''}` is parsed by bash in a way that
  the `''` replacement is treated as an empty string (or worse, eats
  adjacent chars), so an input like `it's a test` became `its a test`
  on the way into SQLite. Every call to `add_message`, `save_tool_result`,
  etc. was affected. Fixed by using an intermediate variable for the
  replacement: `q="''"; s="${1//\'/$q}"`. The new pattern is also robust
  to `set -u` (declarations must be split across statements, not combined
  in one `local`).

### Changed
- **SQLite schema refactored: 1 polymorphic table → 2 normalized tables.**
  The old `messages` table overloaded `role='user'/'assistant'/'tool'` with
  mutually exclusive fields (`content`, `user_input`, `tool_calls`,
  `tool_call_id`) and used string-grepping (`instr(tool_calls, '"id":"…"')`)
  to link tool results back to their calls. New schema:
  - `messages(id, role, content, raw_input, created_at)` with
    `CHECK (role IN ('system','user','assistant'))` — the `tool` role is
    dropped, those messages are derived from `tool_calls` at read time.
  - `tool_calls(id, message_id, name, arguments, result, created_at)` with
    `FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE`
    and an index on `message_id`.
  - Tool results live in `tool_calls.result` (denormalized with the call);
    a single CTE-based `load_history` query joins both tables and
    synthesizes the `role:'tool'` messages in correct order.
  - `cleanup_orphan_tc()` (60+ lines of SQL + bash fallback) is **deleted**;
    `ON DELETE CASCADE` makes orphan tool calls impossible by construction.
  - `prune_history()` is now safe mid-conversation: deleting the oldest N
    `messages` rows auto-drops their `tool_calls` and results via CASCADE.
  - All write helpers go through a new `db_quote` helper (consistent
    SQL string escaping, replaces scattered `${var//\'/''}` blocks).
  - The `sql` helper and `init_db` / `prune_history` set
    `PRAGMA foreign_keys=ON` per connection (required for cascade).
  - `/hist` now shows both tables (messages + tool_calls) for full
    visibility.
- **Tool spec is now the full OpenAI manifest, no rewrite.** Each
  `tools/<name>.json` file is the complete `{"type":"function", "function":{...}}`
  object the API expects — `ai-agent.sh` reads it verbatim instead of
  rebuilding the wrapper in `load_tools()`. The old `input.<param>` schema
  is gone; the spec uses the standard `function.parameters.{properties,
  required}` directly. This kills the duplicate definition: previously
  the tool existed once as JSON in the file and a second time as a
  `jq` filter in `load_tools()`.
- **Explicit `run` binding replaces filename coupling.** The `.sh`
  implementation is no longer matched by `<name>.sh` convention; the JSON
  carries a `run: { interpreter, script }` block that points at it.
  `run.script` is resolved relative to `tools/`, `run.interpreter`
  defaults to `bash` (so any `python3` / `node` / etc. is now a
  one-field change). Missing script → tool is skipped with a `warn`.
- `run_tool()` rewritten: looks the tool up in the loaded `tools_json`
  via `jq --arg`, then execs `"$interpreter" "$TOOLS_DIR/$script_path"`.
  Drops the brittle `${name}.sh` filename glob.
- `load_tools()` now does `cat` + a tiny `jq` validation (skip if
  `type != "function"`, name empty, or `run.script` missing). The
  per-tool description line is derived from the same spec via
  `.function.parameters.properties`, no parallel schema.
- **Tool definitions switched from TOML to JSON.** `tools/<name>.toml`
  → `tools/<name>.json`. Eliminates the `toml2json` external dependency
  and the extra conversion step in `load_tools()`.

## [0.0.3] - 2026-06-02

### Changed
- **JSON layer split**: reads/transforms now use `jq`; writes (`set`/`push`)
  remain on `jj`. `jj` lacks `keys`/`has`/`map`/`select`, while `jq` lacks
  the ergonomic `set X "v"` / `push . X` writes. This split keeps both
  tools in their sweet spot.
- `load_tools()` rewritten: a single `jq -c '{type:"function", function:{name,description,parameters:...}}'`
  filter builds the full OpenAI tool object per tool, replacing manual JSON
  string concatenation.
- `handle_tool_call()`, `cleanup_orphan_tc()`, and API response parsing all
  use `jq -r` for field extraction with `// empty` / `// "stop"` defaults
  (replacing `jj get <field> --raw` with the brittle `2>/dev/null || echo` fallback).
- Tool scripts (`tools/read_file.sh`, `tools/grep_search.sh`, `tools/exec_command.sh`)
  now use `jq -r '.field // ""'` to parse `$1`.
- `ai-agent.sh` line count: 514 → 412 (-20%).
- Documented in `README.md` Dependencies table; `book.md` updated.

### Added
- `.gitattributes` enforcing LF line endings for `*.sh`, `*.json`, `*.jsonl`,
  `*.toml`, `*.md`, `*.yml`.

### Removed
- 19 stale `tmp_test*.sh` / `bench*.sh` files from the repo root.

## [0.0.2] - 2026-06-01

### Changed
- Renamed `DEEPSEEK_AI_AGENT_VERSION` → `AI_AGENT_VERSION` (the script now
  works with any OpenAI-compatible backend, not just DeepSeek)
- `BASE_URL` is now resolved from environment or `curl win/v1`; the API URL
  is derived as `${BASE_URL}/v1/chat/completions`
- `tools/` is now a directory of `<name>.toml` + `<name>.sh` pairs instead of
  a single `.data/tools.json` (hot-pluggable, no main-script edits)
- `load_tools()` no longer uses fragile `${var#*...}` slicing; top-level
  fields come from `jj get`, with a hand-rolled `input.*` key loop.

### Added
- TOML-based tool definition with metadata + Bash implementation
- `tools_cache.json` (machine-readable) and `tools_desc.txt` (human-readable)
- Tool descriptions injected into the system prompt
- `/reload` command for hot-reloading the script
- `README.md`, `LICENSE`, `CHANGELOG.md`, `.editorconfig`, `.shellcheckrc`

## [0.0.2] - 2026-06-01

### Changed
- Renamed `DEEPSEEK_AI_AGENT_VERSION` �?`AI_AGENT_VERSION` (the script now
  works with any OpenAI-compatible backend, not just DeepSeek)
- `BASE_URL` is now resolved from environment or `curl win/v1`; the API URL
  is derived as `${BASE_URL}/v1/chat/completions`
- `tools/` is now a directory of `<name>.toml` + `<name>.sh` pairs instead of
  a single `.data/tools.json` (hot-pluggable, no main-script edits)

### Added
- TOML-based tool definition with metadata + Bash implementation
- `tools_cache.json` (machine-readable) and `tools_desc.txt` (human-readable)
- Tool descriptions injected into the system prompt
- `/reload` command for hot-reloading the script

## [0.0.1] - 2026-06-01

### Added
- Single-file Bash AI Agent (393 lines)
- Three tools: `read_file`, `grep_search`, `exec_command` (in-line `case`)
- SQLite conversation history with `MAX_HISTORY=40` pruning
- Orphan tool-call cleanup
- `/read`, `/grep`, `/exec`, `/save`, `/clear`, `/hist`, `/tools` commands

## [0.0.0] - 2026-06-01

### Added
- Initial prototype
