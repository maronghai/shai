# ai-agent.sh

> An AI Agent terminal client in 412 lines of Bash. Talks to any OpenAI-compatible API,
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
ai-agent.sh          Main script (v0.0.3, 412 lines)
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
