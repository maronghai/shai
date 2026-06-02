# ai-agent.sh

> An AI Agent terminal client in ~780 lines of Bash (v0.1.0). Talks to any OpenAI-compatible API,
> drives a ReAct loop with hot-pluggable tools, and remembers your conversation in SQLite.

> **Note on the repo name `zig-cos`:** this is a historical name �?the project is a
> pure Bash application and has no Zig code. Renaming is tracked as a low-priority
> follow-up.

---

## Quick Start

```bash
git clone <repo> ai-agent && cd ai-agent
chmod +x ai-agent.sh

export BASE_URL="https://api.deepseek.com"   # any OpenAI-compatible endpoint
export MODEL="deepseek-v4-flash"
export API_KEY="sk-..."                       # optional, may be injected by a proxy

./ai-agent.sh
```

Inside the prompt:

```
You> /read README.md
You> summarize the project
You> /save summary.md
```

Type `/help` to see all commands.

## Features

- **Interactive terminal** with readline, history, color
- **SQLite-backed** conversation memory (`MAX_HISTORY=40`)
- **Tool calling** (OpenAI function-calling format)
- **Hot-pluggable tools** �?drop a `<name>.json` (spec) + `<name>.sh` (impl) into `tools/`. The JSON is the full OpenAI tool manifest; the `.sh` is bound via `run.script`
- **Context injection** via `/read`, `/grep`, `/exec`
- **Pluggable backend** �?point `BASE_URL` at DeepSeek, OpenAI, Ollama (via proxy), or any compatible service

## Repository Layout

```
ai-agent.sh          Main script (v0.1.0, ~780 lines)
agents/              Named agent personas (system.md + tools/) [optional]
SYSTEM_PROMPT.md     Default / "no agent selected" system prompt
SYSTEM_PROMPT.md     System prompt
book.md              In-depth guide (12 chapters, ~16k words)
README.md            This file
LICENSE              MIT
CHANGELOG.md         Version history
.editorconfig        Editor defaults
.shellcheckrc        shellcheck config
tools/               Tool definitions (JSON is the full OpenAI spec; `.sh` bound via `run.script`)
.data/               Runtime data (SQLite, cache, history) �?gitignored
.tmp/                Runtime temp files �?gitignored
```

For a deep dive read **[book.md](./book.md)**. It walks through every feature,
the database schema, the ReAct loop, the tool spec format, and how to
extend with custom tools.

## Adding a Tool

1. **Define the tool** in `tools/<name>.json`. The file is the full OpenAI tool manifest — `ai-agent.sh` reads it as-is with no rewriting. Add a `run` field to bind the implementation:

   ```json
   {
     "type": "function",
     "function": {
       "name": "list_dir",
       "description": "List files in a given path",
       "parameters": {
         "type": "object",
         "properties": {
           "path": {
             "type": "string",
             "description": "Directory to list"
           }
         },
         "required": ["path"]
       }
     },
     "run": {
       "interpreter": "bash",
       "script": "list_dir.sh"
     }
   }
   ```

2. **Implement** the tool in `tools/list_dir.sh` (the path is from `run.script`, relative to `tools/`):

   ```bash
   #!/usr/bin/env bash
   path=$(echo "$1" | jq -r '.path // "."' 2>/dev/null)
   if [[ -d "$path" ]]; then
       ls -la "$path"
   else
       echo '{"success":false,"error":"Directory not found"}'
       exit 1
   fi
   ```

3. **Reload**:

   ```
   You> /tools reload
   ```

No changes to the main script are required.

## Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| `bash` 4.0+ | Script runtime | preinstalled on most systems |
| `sqlite3` (json1 ext) | Conversation storage | `brew install sqlite3` / `apt install sqlite3` |
| `curl` | API calls | preinstalled |
| `jq` | JSON reads & transforms | `brew install jq` / `apt install jq` |
| `jj` | JSON writes (`set`/`push`) | `brew install tidwall/tap/jj` |

## Multi-Agent (v0.1.0+)

`ai-agent.sh` supports switching between named agent personas, each with its
own system prompt, conversation history, and tool set.

```
agents/
├── coordinator/
│   ├── system.md              ← orchestrator that uses agent_delegate
│   └── (no tool overrides)
└── code-reviewer/
    ├── system.md              ← read-only review persona
    └── tools/
        ├── exec_command.json  ← override manifest (description only, no run)
        └── exec_command.sh    ← refuses with a disabled-error stub
```

Each `system.md` can declare metadata in a YAML-ish frontmatter block:

```markdown
---
description: Read-only review of source code
tags: review, read-only
---

# Code reviewer — read-only review of source code
...
```

`description` populates the second column of `/agents` and is exposed to
sub-agents via `agent_list`. `tags` lets you filter with `/agents @tag`.

Commands:

| Command | Effect |
|---|---|
| `/agent` | Show current agent (name, description, tags, db, msgs, tools) |
| `/agent <name\|id>` | Switch to `agents/<name>/` (or `default`); `id` is the 1-based number from `/agents` |
| `/agent reload` | Reload the current agent's prompt + tools |
| `/agents` | List all available agents (numbered), current one marked `*` |
| `/agents @tag` | List only agents whose frontmatter tags include `tag` |
| `/board [topic]` | List blackboard topics or show entries for one |

Built-in tools for inter-agent communication:

- `board_write` — write a row to the shared blackboard (`.data/blackboard.db`)
- `board_read` — read rows for a topic, optionally after a known id
- `board_list` — list distinct topics (with optional prefix filter)
- `agent_list` — list available agents and their one-line descriptions
- `agent_delegate` — run a sub-task in a fresh named-agent context, with
  `exec_command` and `agent_delegate` removed from its toolset and depth capped
  at 2. The sub-agent's final reply is returned to the caller.

Storage:

- The default / unswitched context uses `.data/chat.db` and `SYSTEM_PROMPT.md`.
- Each named agent gets its own `.data/chat_<name>.db` and
  `agents/<name>/system.md`, so histories never bleed across personas.
- The blackboard is shared (`.data/blackboard.db`) so agents can coordinate.

Pre-built personas:

- **`coordinator`** — orchestrator that breaks tasks into sub-tasks and
  delegates each to a specialist, then synthesizes the results.
- **`code-reviewer`** — read-only code review. Overrides `exec_command` so
  shell execution is impossible in this agent.

See [book.md chapter 13](./book.md#13-章多-agent-编排) for the full protocol,
blackboard schema, and delegation safety model.

## Security Notice

This project executes arbitrary shell commands via:

- The `/exec` user command
- The `exec_command` tool that the AI can call autonomously
- `process_input()` and `tools/exec_command.sh` both use `eval`

**Do not run in an untrusted environment.** Recommended mitigations:

- Run inside a container or VM
- Audit every `tool:` line in stderr (every tool call is logged)
- Long term: replace the bare `eval` with a whitelisted command runner

`BASE_URL` is read from the environment or from `curl win/v1` (a LAN HTTP
convention). The `win/v1` endpoint can observe your prompts and forge responses �?use only on trusted networks. See [book.md chapter 11](./book.md#�?11-章安全注意事�?
for the full security analysis.

## License

[MIT](./LICENSE). © 2026.

## See Also

- [book.md](./book.md) �?full documentation in Chinese
- [CHANGELOG.md](./CHANGELOG.md) �?version history
