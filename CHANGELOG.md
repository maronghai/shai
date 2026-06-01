# Changelog

All notable changes to **ai-agent.sh** are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [Unreleased]

### Added
- `<think>...</think>` blocks in model replies are surfaced as a dim
  `think: <content>` line above the answer (e.g. DeepSeek R1, reasoning models).
  Stripped from the saved message so the conversation log stays clean.

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
