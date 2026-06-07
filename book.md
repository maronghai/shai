# 《AI Agent Shell 实战指南》—— 从零掌握 ai-agent.sh

## 前言

在人工智能飞速发展的今天，AI 编程助手已成为开发者离不开的工具。但大多数 AI 助手只停留在"问答"层面，无法真正操作你的代码库、执行命令或读取文件。

**ai-agent.sh** 打破了这个局限——它仅用 ~1330 行 Bash 脚本（v0.0.14），就构建了一个完整的 AI Agent 终端环境。它连接任何 OpenAI 兼容的 API，让你的终端变成一个**能读、能搜、能执行、能自主调用工具**，并且**支持多 agent 切换、委派和 7 人 AI Coding Team 编排**的智能代理。

本书将带你从零开始，全面掌握 ai-agent.sh 的使用、原理与扩展。

---

## 第 1 章：初识 ai-agent.sh

### 1.1 什么是 ai-agent.sh

ai-agent.sh 是一个基于 Bash 脚本的 AI Agent 终端程序，它：

- 通过 API 连接 **DeepSeek** 大模型
- 在终端中提供交互式对话界面
- 支持 **工具调用**（Tool Calling）：读取文件、搜索代码、执行命令
- 使用 **SQLite** 持久化对话历史
- 所有功能封装在 **单个脚本文件**（~1330 行，含多 agent 与 AI Coding Team 编排）中

### 1.2 核心特性

| 特性 | 说明 |
|------|------|
| 交互式终端 | 彩色提示符、readline 支持、命令历史 |
| 对话历史 | SQLite 存储，可回溯、可清空 |
| 工具调用 | 模型可自主调用 `read_file`、`grep_search`、`exec_command` |
| 上下文注入 | 通过 `/read`、`/grep`、`/exec` 将信息注入对话 |
| 响应保存 | 将 AI 回复保存到文件 |
| 极简依赖 | 只需 `bash`、`sqlite3`、`curl`、`jq`、`jj` |

### 1.3 架构一览

```
用户输入 ──→  process_input()  （处理 / 命令）
                  │
                  ▼
          build_messages()  （构建消息体）
                  │
                  ▼
          curl → DeepSeek API
                  │
                  ▼
          解析响应
                  │
          ┌───────┴───────┐
          ▼               ▼
      tool_calls?      正常回复
          │               │
          ▼               ▼
   handle_tool_call()   add_message()
          │               │
          ▼               ▼
   save_tool_result()   显示给用户
          │
          ▼
   重新请求 API（循环）
```

---

## 第 2 章：安装与配置

### 2.1 环境要求

在开始之前，请确保系统已安装以下工具：

```bash
# 检查是否已安装
bash --version       # Bash 4.0+
sqlite3 --version    # SQLite 3.x
curl --version       # curl
jq --version         # JSON 查询与变换 (https://jqlang.org)
jj --version         # JSON 写入工具 (https://github.com/tidwall/jj)
```

> **为什么同时需要 `jq` 和 `jj`？**
> - `jj` 的 `set` / `push` / `del` 等写操作语法极简
> - `jq` 的查询与变换能力（`keys`、`has`、`length`、`map`、`select`、null 默认值）远超 `jj`
> - 本项目采用 **写用 `jj`、读用 `jq`** 的混合策略

如果缺少 `jj`，安装方式：

```bash
# macOS
brew install tidwall/tap/jj

# Linux (下载二进制)
curl -L https://github.com/tidwall/jj/releases/latest/download/jj-0.7.5-linux-amd64 -o /usr/local/bin/jj
chmod +x /usr/local/bin/jj
```

如果缺少 `jq`：

```bash
# macOS
brew install jq

# Debian/Ubuntu
sudo apt install jq

# Windows (chocolatey)
choco install jq
```

### 2.2 获取脚本

```bash
git clone <仓库地址> ai-agent
cd ai-agent
chmod +x ai-agent.sh
```

### 2.3 配置 API 密钥

脚本通过环境变量 `API_KEY` 获取密钥：

```bash
# 方式一：直接设置环境变量
export API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# 方式二：写入 ~/.bashrc 或 ~/.zshrc
echo export API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" >> ~/.zshrc

# 方式三：脚本会尝试 curl win/ds 获取密钥（局域网部署场景）
```

### 2.4 选择模型

通过 `MODEL` 环境变量选择模型：

```bash
export MODEL="deepseek-v4-flash"    # 默认，快速模型
export MODEL="deepseek-v4"          # 完整模型
```

### 2.5 启动

```bash
./ai-agent.sh
```

你会看到：

```
DeepSeek AI Agent v1.0.0  (deepseek-v4-flash)
Type /help for commands

You>
```

---

## 第 3 章：基础用法

### 3.1 开始对话

在 `You>` 提示符下直接输入问题：

```
You> 请介绍一下当前目录的结构
```

AI 会读取目录内容并回答：

```
Agent> 当前目录包含以下文件：
- ai-agent.sh（主脚本）
- SYSTEM_PROMPT.md（系统提示词）
- .data/（数据目录）
  - ai-agent.db（**统一** SQLite 数据库：messages / tool_calls / board / tasks / task_events / team_state）
  - tools.json（工具定义）
```

### 3.2 多轮对话

ai-agent.sh 会记住上下文。你可以连续提问：

```
You> 这个脚本有多少行？
Agent> ai-agent.sh 共 780 行左右（含多 agent 支持）。

You> 其中主要有哪些功能函数？
Agent> 主要功能函数包括：
- init_db() - 初始化数据库
- add_message() - 添加消息
- handle_tool_call() - 处理工具调用
- process_input() - 处理用户输入
- build_messages() - 构建 API 请求体
- load_history() - 加载历史对话
... ...
```

### 3.3 中断与退出

| 操作 | 功能 |
|------|------|
| `Ctrl+C` | 中断 AI 正在生成的回复 |
| `Ctrl+D` | 退出程序 |
| `/exit` | 退出程序 |

### 3.4 内置命令总览

| 命令 | 作用 |
|------|------|
| `/read <路径>` | 读取文件内容并注入上下文 |
| `/grep <模式>` | 搜索代码并注入结果 |
| `/exec <命令>` | 执行 shell 命令 |
| `/save <路径>` | 保存上一条 AI 回复到文件 |
| `/clear` | 清空对话历史 |
| `/hist` | 查看历史记录 |
| `/tools` | 显示可用工具列表 |
| `/tools reload` | 重新加载工具配置 |
| `/help` | 显示帮助信息 |
| `/exit` | 退出 |

---

## 第 4 章：上下文注入命令

这是 ai-agent.sh 最核心的能力——将本地信息注入 AI 对话。

### 4.1 `/read` — 文件读取

**语法：** `/read <文件路径>`

```
You> /read ai-agent.sh
OK: Here is the content of `ai-agent.sh`:
...

You> 帮我分析这个脚本的安全性问题
Agent> 基于读取的代码，我发现以下潜在安全问题：
1. eval 执行用户命令 (process_input 和 handle_tool_call 中)
2. API_KEY 以明文方式传输
... ...
```

**处理流程：** 脚本读取文件内容，加上 `OK:` 前缀和 markdown 代码块标记，然后送入 AI 对话。

### 4.2 `/grep` — 代码搜索

**语法：** `/grep <正则模式> [目录]`

```
You> /grep handle_tool_call
OK: Search results for `handle_tool_call`:
ai-agent.sh:123:handle_tool_call() {
ai-agent.sh:145:  handle_tool_call "$tc"
...

You> /grep def __init__ src/
OK: Search results for `def __init__` in `src/`:
src/main.py:10:    def __init__(self, name):
src/utils.py:5:    def __init__(self, config):
```

**注意：** 搜索结果默认限制 100 行，防止上下文过长。

### 4.3 `/exec` — 命令执行

**语法：** `/exec <shell命令>`

```
You> /exec git log --oneline -5
OK: Command output for `git log --oneline -5`:
a1b2c3d fix: 修复内存泄漏
e4f5g6h feat: 添加用户认证
i7j8k9l refactor: 重构数据库模块
...

You> /exec ls -la
OK: Command output for `ls -la`:
total 40
drwxr-xr-x  8 user  staff   256  3月 15 10:00 .
drwxr-xr-x  3 user  staff    96  3月 15 09:55 ..
-rwxr-xr-x  1 user  staff  13129  3月 15 09:58 ai-agent.sh
```

**危险提示：** `/exec` 执行任意命令——请确保你信任所在环境。

### 4.4 注入原理

当输入以 `/read`、`/grep` 或 `/exec` 开头时，`process_input()` 函数会：

1. 解析命令和参数
2. 执行对应操作（读取文件 / 搜索 / 执行）
3. 格式化结果为 `OK: ...` 或 `ERR: ...`
4. 返回给主循环，作为本次用户消息的内容发送给 AI

这意味着 AI 模型不是直接看到你的命令，**而是看到命令的执行结果**。

---

## 第 5 章：AI 工具调用（Tool Calling）

这是 ai-agent.sh 最强大的功能——AI 模型可以**自主决定**调用工具。

### 5.1 工具定义

工具配置在 `.data/tools.json` 中，采用 OpenAI 函数调用格式：

```json
[
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read the content of a file at the given path",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute or relative path to the file"
          }
        },
        "required": ["path"]
      }
    }
  }
]
```

目前内置 **三个工具**：

| 工具名 | 功能 | 参数 |
|--------|------|------|
| `read_file` | 读取文件内容 | `path`: 文件路径 |
| `grep_search` | 搜索代码 | `pattern`: 正则, `path`: 目录 |
| `exec_command` | 执行命令 | `command`: shell 命令 |

### 5.2 工具调用全流程

当 AI 决定调用工具时，API 返回 `finish_reason: "tool_calls"`，触发以下流程：

```
1. API 返回 tool_calls 响应
2. save_assistant_tool_call() 保存 AI 消息
3. 遍历 tool_calls 数组
4. 对每个工具调用 handle_tool_call()
   ├─ 解析工具名称、参数、ID（用 jq）
   ├─ 执行对应操作
   └─ save_tool_result() 保存结果
5. prune_history() 修剪历史
6. load_history() 重新加载
7. 构建新请求（包含工具结果）
8. 重新调用 API
```

这个循环（称为 **ReAct 循环**）会不断重复，直到 AI 生成最终回复。

### 5.3 工具调用示例

```
You> 帮我看看 ai-agent.sh 中 init_db 函数的实现

Agent> 让我读取文件来分析...
  tool: read_file({"path":"ai-agent.sh"}) [id=call_xxx]

Agent> init_db() 函数的实现如下：
    init_db() {
        if sqlite3 "$DB_PATH" ...
            sqlite3 "$DB_PATH" "DROP TABLE messages" || true
        fi
        sqlite3 "$DB_PATH" "
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT,
                ...
            );
        " || true
    }
    
该函数首先检查表结构是否需要迁移（旧版没有 tool_calls 列），
然后创建或保留 messages 表...
```

### 5.4 结果截断

工具执行结果超过 **10000 字符** 时自动截断：

```
... [truncated, 25000 total chars]
```

这是为了防止超出模型的上下文窗口。

---

## 第 6 章：对话历史管理

### 6.1 存储架构

所有消息存储在**统一** SQLite 数据库 `.data/ai-agent.db` 的 `messages` 表中。
每个 agent 的历史通过 `agent_id` 列分区，复合主键 `(agent_id, id)`，每个 agent
拥有自己独立的 id 序列（从 1 开始）。

```sql
CREATE TABLE messages (
    agent_id   TEXT NOT NULL DEFAULT 'default',
    id         INTEGER NOT NULL,        -- per-agent 序列（从 1 开始）
    role       TEXT NOT NULL CHECK (role IN ('system','user','assistant')),
    content    TEXT,
    raw_input  TEXT,                    -- 用户的原始输入（仅 user 消息）
    thinking   TEXT,                    -- 思考链
    created_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (agent_id, id)
);
```

### 6.2 四种角色

| role | 说明 | 有 content | 有 tool_calls | 有 tool_call_id |
|------|------|-----------|--------------|----------------|
| `system` | 系统提示词 | 是 | 否 | 否 |
| `user` | 用户消息 | 是 | 否 | 否 |
| `assistant` | AI 回复 | 可能 | 可能 | 否 |
| `tool` | 工具执行结果 | 是 | 否 | 是 |

### 6.3 历史修剪

`MAX_HISTORY=40` 限制最大消息数。超过时删除最早的消息（按 per-agent 序列）：

```bash
prune_history() {
    local agent
    agent=$(chat_table_id)              # current agent's partition
    count=$(sqlite3 "$AI_AGENT_DB" "SELECT COUNT(*) FROM messages WHERE agent_id=$(db_quote "$agent")")
    if [[ $count -gt $MAX_HISTORY ]]; then
        remove=$((count - MAX_HISTORY))
        sqlite3 "$AI_AGENT_DB" "DELETE FROM messages
            WHERE agent_id=$(db_quote "$agent") AND id IN
                (SELECT id FROM messages WHERE agent_id=$(db_quote "$agent") ORDER BY id LIMIT $remove)"
    fi
}
```

### 6.4 孤儿清理

`cleanup_orphan_tc()` 函数检测并删除那些"发了 tool_calls 但没有对应 tool 结果"的孤立消息——这在中断或出错后很有用。

### 6.5 查看历史

```
You> /hist
id  role       content                                                         user_input  created_at
--  ---------  --------------------------------------------------------------  ----------  -------------------
1   system     # role You are an AI coding assistant...                                    2025-03-15 10:00:00
2   user       Hello                                                           Hello       2025-03-15 10:00:05
3   assistant  Hello! How can I help you today?                                            2025-03-15 10:00:07
```

---

## 第 7 章：深入理解代码架构

### 7.1 启动流程

```
1. 设置环境变量和常量
2. 创建 .data/ 和 .tmp/ 目录
3. 安装退出信号处理 (trap)
4. 检查依赖 (sqlite3)
5. 读取 SYSTEM_PROMPT.md
6. init_db() — 初始化/迁移数据库
7. cleanup_orphan_tc() — 清理孤立工具调用
8. load_history() — 加载历史消息
9. load_tools() — 加载工具配置
10. 加载 readline 历史
11. 显示欢迎信息
12. 进入主循环
```

### 7.2 主循环

```bash
while true; do
    read -e -p "You> " -r input
    
    # 处理空输入
    # 保存到 readline 历史
    
    case "$input" in
        /exit) exit 0 ;;
        /help) help; continue ;;
        /clear) ... ;;
        /hist) ... ;;
        /tools*) ... ;;
        /save*) ... ;;
    esac
    
    # 处理 /read /grep /exec 注入
    proc_result=$(process_input "$input")
    
    # 构建消息体
    msgs_json=$(build_messages "$user_content")
    
    # 内部 ReAct 循环
    while (( _inner )); do
        # 调用 API
        # 解析响应
        # 如果 tool_calls，处理并继续循环
        # 否则，输出回复并退出循环
    done
    
    # 修剪历史
done
```

### 7.3 消息体构建

`build_base_messages()` 构造的 JSON 结构：

```json
[
  {
    "role": "system",
    "content": "(SYSTEM_PROMPT.md 内容)"
  },
  {
    "role": "user",
    "content": "...",
    "user_input": "原始命令"
  },
  {
    "role": "assistant",
    "content": "...",
    "tool_calls": [...]
  },
  {
    "role": "tool",
    "content": "...",
    "tool_call_id": "..."
  }
]
```

然后 `build_messages()` 追加当前用户消息。

### 7.4 API 调用

```bash
post_data=$(jj set model "$MODEL" messages "$msgs_json")
if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    post_data=$(echo "$post_data" | jj set tools "$tools_json")
fi

response_content=$(curl -sS \
    --connect-timeout 15 \
    --max-time 120 \
    "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    --json "$post_data")
```

超时设置：
- 连接超时：15 秒
- 最大超时：120 秒

### 7.5 JSON 处理

脚本采用 **写用 `jj`、读用 `jq`** 的混合策略——`jq` 负责查询与变换，`jj` 负责写入与数组追加。

```bash
# 获取字段
jq -r '.choices[0].message.content // empty' <<< "$response"

# 设置字段
jj set model "deepseek-v4" messages "$msgs"

# 遍历数组
for ((i=0; ; i++)); do
    tc=$(echo "$tc_array" | jq -c ".[$i] // empty" 2>/dev/null)
    [[ -z "$tc" ]] && break
    ...
done
```

注意：脚本中有些地方用 `jj` 解析带点的字段（如 `function.name`），这实际上是 `jj` 的一个已知局限——如果需要匹配带点的字段名，需要转义。

---

## 第 8 章：高级用法

### 8.1 自定义工具

编辑 `.data/tools.json` 添加新工具。例如添加一个 `list_dir` 工具：

```json
[
  {
    "type": "function",
    "function": {
      "name": "list_dir",
      "description": "List files and directories in a given path",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Directory path to list"
          }
        },
        "required": ["path"]
      }
    }
  }
]
```

然后在 `ai-agent.sh` 的 `handle_tool_call()` 的 `case` 中添加：

```bash
case "$name" in
    read_file) ... ;;
    grep_search) ... ;;
    exec_command) ... ;;
    list_dir)
        local path=$(echo "$args" | jq -r '.path // "."' 2>/dev/null)
        result=$(ls -la "$path")
        ;;
esac
```

修改后执行 `/tools reload` 重新加载。

### 8.2 自定义系统提示词

编辑 `SYSTEM_PROMPT.md` 可以改变 AI 的行为和身份。例如改为：

```markdown
# role
You are a senior DevOps engineer with expertise in Kubernetes and Docker.

# capabilities
- Troubleshoot container issues
- Write Dockerfiles and docker-compose files
- Analyze k8s manifests
```

### 8.3 保存回复到文件

```
You> 帮我写一个 Python 单元测试示例

Agent> 以下是一个使用 unittest 的示例：
... (AI 生成内容)

You> /save test_example.py
OK: Saved to test_example.py
```

### 8.4 重定向 API 地址

默认使用 `https://api.deepseek.com/chat/completions`。

可以通过环境变量或脚本中修改 `API_URL` 指向其他兼容 OpenAI API 的地址：

```bash
export API_URL="https://your-proxy.example.com/v1/chat/completions"
```

### 8.5 组合使用

最强大的用法是组合多个命令：

```
You> /read ai-agent.sh
You> 这个脚本大约有多少行？
You> /exec wc -l ai-agent.sh
You> 与我预估的一致吗？
```

---

## 第 9 章：常见问题与排错

### 9.1 "sqlite3 is required"

**问题：** 未安装 sqlite3。

**解决：**
```bash
# macOS
brew install sqlite3

# Ubuntu/Debian
sudo apt install sqlite3

# CentOS/RHEL
sudo yum install sqlite
```

### 9.2 "jj: command not found"

（注：v0.0.3+ 还需 `jq`。安装见 2.1 节。）

**问题：** JSON 处理器缺失。

**解决：**
```bash
# macOS
brew install tidwall/tap/jj

# Linux
curl -L https://github.com/tidwall/jj/releases/latest/download/jj-0.7.5-linux-amd64 -o /usr/local/bin/jj
chmod +x /usr/local/bin/jj
```

### 9.3 API 请求失败

**可能原因：**
- API_KEY 未设置或无效
- 网络不通
- API 端点不可达

**排查：**
```bash
# 测试 API 可用性
curl -sS https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  --json '{"model":"deepseek-chat","messages":[{"role":"user","content":"hi"}]}'
```

### 9.4 对话历史损坏

如果数据库出现问题，可以安全删除（会清空所有 agent 的对话历史、board、tasks）：

```bash
rm -rf .data/ai-agent.db
```

下次启动时会自动重建（`init_db` 调用 `team/schema.sql` 里的 `CREATE TABLE IF NOT EXISTS`）。

### 9.5 乱码或颜色显示问题

脚本使用 ANSI 转义码着色。如果显示异常：

```bash
# 检查终端是否支持颜色
echo -e "\033[1;32mGreen\033[0m"

# 禁用颜色（手动修改脚本前几行的 R/B/G/Y/C/M 变量）
```

### 9.6 工具调用循环卡死

如果 AI 不断调用工具而不生成最终回复，可能是模型行为异常。可以：

1. 按 `Ctrl+C` 中断
2. 用 `/clear` 清空历史
3. 重试，或修改 SYSTEM_PROMPT 引导模型行为

---

## 第 10 章：扩展与定制

### 10.1 添加更多工具

内置三个工具只是起点。你可以添加：

- `write_file` — 写入/修改文件（需要谨慎处理权限）
- `git_commit` — 创建 git 提交
- `npm_test` — 运行测试
- `docker_ps` — 查看容器状态
- `http_get` — 发送 HTTP 请求

### 10.2 适配其他模型

虽然默认使用 DeepSeek，但只要能兼容 OpenAI 的 Chat Completion API 格式，任何模型都可以：

```bash
# 支持 OpenAI
export API_KEY="sk-..."
export MODEL="gpt-4"
export API_URL="https://api.openai.com/v1/chat/completions"

# 支持 Anthropic (via proxy)
# 支持本地 Ollama (via proxy)
export API_URL="http://localhost:8080/v1/chat/completions"
```

### 10.3 持久化配置

将常用配置写入脚本或封装 wrapper：

```bash
#!/usr/bin/env bash
# wrapper.sh — 我的 AI Agent 启动器
export API_KEY="sk-xxx"
export MODEL="deepseek-v4"
export API_URL="https://my-proxy.example.com/v1/chat/completions"
exec ./ai-agent.sh
```

### 10.4 集成到编辑器

可以将 ai-agent.sh 作为 Vim/Neovim 的终端插件：

```vim
" 在 Vim 中打开终端窗口
:terminal ./ai-agent.sh
```

或者通过 tmux 分屏使用。

---

## 第 11 章：安全注意事项

### 11.1 eval 的安全性

脚本两处使用了 `eval`：

1. `process_input()` 中的 `/exec` 命令
2. `handle_tool_call()` 中的 `exec_command` 工具

**这意味着：** AI 模型可以执行任意 shell 命令。

**防护措施：**
- 不要在你不信任的网络或机器上运行
- 监控 AI 的 tool calls 日志（每个工具调用都会打印到 stderr）
- 考虑在容器或沙箱中运行

### 11.2 API 密钥管理

- 密钥通过环境变量传递，可能被进程列表看到
- 不要在公开场合分享 `.data/` 目录（虽然不存密钥）
- 使用 `.env` 文件配合 direnv 管理密钥

### 11.3 SQL 注入风险

脚本中直接拼接 SQL 查询：

```bash
sql "INSERT INTO messages (role, content) VALUES ($role, $content)"
```

虽然 `content` 使用了 `${content//\/\\\}` 转义单引号，但仍需注意——不要在不可控内容中依赖这个机制。

---

## 第 12 章：实战案例

### 12.1 代码审查

```
You> /read src/main.py
You> 请审查这个文件的代码质量，指出潜在问题
```

### 12.2 Bug 定位

```
You> /read logs/error.log
You> /grep "NullPointerException" src/
You> 根据日志和代码，分析这个 NullPointerException 的原因
```

### 12.3 重构建议

```
You> /read src/legacy.js
You> /exec wc -l src/legacy.js
You> 这个文件有 800 行，请建议如何拆分成多个模块
```

### 12.4 自动化脚本编写

```
You> 帮我写一个 bash 脚本，批量重命名当前目录下的所有 .jpg 文件，
    添加日期前缀。先用 /exec ls *.jpg 看看有哪些文件
You> 好的，现在写脚本并测试
```

### 12.5 学习新代码库

```
You> /exec find . -name "*.py" | head -20
You> /read requirements.txt
You> /read README.md
You> 请总结这个项目的架构和技术栈
```

---

## 第 13 章：多 Agent 编排

从 v0.1.0 开始，ai-agent.sh 支持在同一进程/脚本内切换多个 agent persona，并允许一个 agent 委派任务给另一个 agent 跑。本章解释这套机制是怎么拼起来的。

### 13.1 动机

单 agent 在面对"一个任务需要先调研再写代码再 review"这类多步工作流时，会出现几个问题：

- **角色混淆**：同一个 system prompt 既要负责搜索资料，又要负责遵守代码风格，还要负责做 code review，模型很容易在长上下文里把规则串台。
- **上下文污染**：写代码时贴的 `import` 列表，污染了 review 阶段的注意力。
- **工具膨胀**：review 阶段其实只想用 `read_file` + `grep_search`，但 `exec_command` 必须保留在工具列表里（因为前面步骤要用），所以风险敞口大。

解法是 **persona 隔离 + 黑板通信**：每个 agent 自己的 system prompt / DB / 工具集都是独立的；要协调，就写到共享 blackboard 上读。

### 13.2 目录布局

```
ai-agent.sh
SYSTEM_PROMPT.md          # 默认 agent 的 system prompt（root context）
agents/
├── coordinator/
│   └── system.md         # 协调者 persona
└── code-reviewer/
    ├── system.md         # 只读 review persona
    └── tools/
        ├── exec_command.json   # 覆盖基线同名工具
        └── exec_command.sh     # 拒绝执行，输出错误 JSON
tools/
├── read_file.{json,sh}
├── grep_search.{json,sh}
├── exec_command.{json,sh}
├── board_read.{json,sh}        # blackboard
├── board_write.{json,sh}
├── board_list.{json,sh}
├── agent_delegate.{json,sh}    # 委派
└── agent_list.{json,sh}        # 列出可用 agent
.data/
├── ai-agent.db            # 统一 SQLite（messages/tool_calls/board/tasks/task_events/team_state）
├── .current_agent         # 持久化当前 agent 名
├── tools_cache.json       # default agent 的工具缓存
├── tools_cache_coordinator.json
└── tools_desc.txt         # default agent 的工具描述缓存
```

每个 agent 的历史是**独立**的：统一 `.data/ai-agent.db` 里通过 `agent_id` 列分区。
`messages` 主键 `(agent_id, id)`，每个 agent 有自己的 id 序列（从 1 开始）。
切换 agent 只改 `CURRENT_AGENT`，DB 文件不变。

### 13.3 切换命令

```
/agent                     # 当前 agent 多行状态: name/description/tags/db/msgs/tools
/agent <name|id>           # 切到指定 agent；id 是 /agents 列表的 1-based 编号
/agent default             # 切回默认（无 agent）
/agent reload              # 重新读 system.md + 重新生成 tools 缓存
/agents                    # 列出所有可用 agent（带 1-based 编号），当前 agent 前面加 *
/agents @tag               # 只列 tags 包含 @tag 的 agent
```

`/agents` 输出形如：

```
*  1. default            role
   2. code-reviewer      Reviews source code in read-only mode   [review, read-only]
   3. coordinator        Multi-agent orchestrator                [orchestration, planning, delegation]
```

数字编号稳定：`1` 永远是 default，`2..N` 永远按 `agents/<name>/` 目录迭代顺序。
用 `/agents @review` 过滤后，剩下的 agent **保留原始编号**——所以
"用 `/agents @review` 找到 code-reviewer" 和 "直接 `/agents` 找" 都能用
`/agent 2` 切过去。

切换做了四件事：

1. 校验新名字 `^[a-zA-Z0-9_-]+$`（或通过 `_resolve_agent_id` 把数字
   翻译回名字），不通过就报错不改状态。
2. 检查 `agents/<name>/system.md` 存在；不存在就报错。
3. 把 `CURRENT_AGENT` 写到 `.data/.current_agent`。
4. 清掉 `tools_cache` + `tools_desc`，下一次循环里 `load_tools` 重新生成。

`/agent` 无参的多行输出形如：

```
name=coordinator
description=Multi-agent orchestrator
tags=orchestration, planning, delegation
db=./.data/chat_coordinator.db msgs=0 tools=8
```

`description` 和 `tags` 来自 agent 自己的 `system.md` frontmatter（见 13.4），
没有就只输出 `name` / `db` / `msgs` / `tools`。

### 13.4 agent frontmatter 与标签过滤

`agents/<name>/system.md` 的顶部可以用一段 `---` 包裹的 YAML-ish 块声明
agent 的元数据：

```markdown
---
description: Multi-agent orchestrator
tags: orchestration, planning, delegation
---

# Coordinator — multi-agent orchestrator

You are the coordinator agent...
```

字段：

| 字段 | 用途 |
|---|---|
| `description` | 一句话简介。`/agents` 用它做第二列（之前用的是 H1 行），`agent_list.sh` 把它暴露给子 agent 的 LLM 上下文 |
| `tags` | 逗号分隔的标签。`/agents @<tag>` 按它过滤；`agent_list.sh` 也作为 `tags` 字段返回 |

`description` 和 `tags` 都可选。**没有 frontmatter 时仍用 H1 行 + 无 tags 列**，
所以老 persona 不会破。

`/agents @tag` 的实现：`list_agents` 接一个 `filter_tag` 形参，把每个 agent
的 `tags` 按逗号拆开 trim 后逐项匹配；空过滤就是不过滤。

### 13.5 工具命名空间合并

`load_tools` 加载顺序是：

1. 扫 `tools/*.json` → 8 个基线工具（含 blackboard + agent 工具）。
2. 如果 `CURRENT_AGENT` 非空，再扫 `agents/$CURRENT_AGENT/tools/*.json`。
3. 用 `jq` `reverse | unique_by(.function.name) | reverse` 去重，最后出现的胜出。

`code-reviewer/tools/exec_command.json` 的 `function.name` 和基线一样，所以合并后基线那条被 `code-reviewer` 的覆盖。**这就是 agent 工具覆写机制的本质**——同名声明，agent 优先。

`exec_command.sh` 的覆写版本是个 stub：

```sh
#!/bin/sh
echo '{"success":false,"error":"exec_command is disabled in this agent (read-only review mode)"}'
exit 1
```

当 code-reviewer 跑的时候，LLM 仍然在工具列表里看到 `exec_command`（因为 OpenAI 协议要求 tools 数组不变），但凡调用都会拿到 `success:false` 的响应。这是**最小权限示范**——不要靠"prompt 告诉它不要 exec"，要在工具层硬关。

### 13.6 Blackboard

黑板是一个 SQLite 表，所有 agent 共享——统一在 `.data/ai-agent.db` 的 `board` 表里：

```sql
CREATE TABLE board (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    agent      TEXT    NOT NULL DEFAULT '',
    topic      TEXT    NOT NULL,
    payload    TEXT    NOT NULL,
    reply_to   INTEGER,
    created_at TEXT    DEFAULT (datetime('now'))
);
CREATE INDEX idx_board_topic ON board(topic);
CREATE INDEX idx_board_reply ON board(reply_to);
```

字段语义：

- `id`：自增主键，按时间单调递增。
- `agent`：写入者名（空串表示 default）。
- `topic`：业务主键，调用方自己定义；建议格式 `<task-id>[:<sub-topic>]`（如 `review-001:summary`）。
- `payload`：任意文本，最长 8000 字（`agent_delegate` 写入时强制截断）。
- `reply_to`：可空，指向另一行的 `id`，用于把多条记录串成线程。
- `created_at`：写入时间，UTC，`datetime('now')`。

工具：

| 工具 | 输入 | 行为 |
|------|------|------|
| `board_write` | `topic, payload, reply_to?` | `INSERT`；返回 `{id, topic, agent, created_at}` |
| `board_read` | `topic, since_id?, limit?` | `SELECT WHERE topic=? AND id>? ORDER BY id LIMIT ?`；返回 JSON 数组 |
| `board_list` | `prefix?` | `SELECT DISTINCT topic ORDER BY topic`；返回 JSON 数组 |

人检视用 `/board [topic]`：无参列所有 distinct topic，有参列该 topic 的所有行（含每行的 `id agent created_at reply_to payload`）。

### 13.7 agent_delegate 协议

`agent_delegate(agent, task, topic?)` 跑这个流程：

1. 校验 `agent` 名（regex + 存在性 + 系统级 `default` 拒绝）。
2. 校验 `task` 长度 ≤ 8000 字。
3. 在 blackboard 上写一行占位记录，拿到 `parent_id`。
4. `fork` 一个 `bash ai-agent.sh` 子进程，环境里设置：
   - `NON_INTERACTIVE=1`（让脚本走 `run_non_interactive` 入口）
   - `AGENT_NAME=<agent>`（子 agent 走它的 context）
   - `DELEGATION_DEPTH=$(( 当前 + 1 ))`
   - `PARENT_ID=<parent_id>`（子 agent 完成后把回复写到这行的 reply_to）
   - `TASK=<task>` + `TOPIC=<topic>`
5. 父进程轮询 blackboard：`SELECT 1 FROM board WHERE id=$PARENT_ID AND reply_to IS NOT NULL LIMIT 1`，直到出现 reply 行；timeout 120s。
6. 读出 reply 行的 payload，截断到 8000 字，返回给父 agent 的工具结果。

子进程侧 `run_non_interactive()` 做：

1. `switch_agent "$AGENT_NAME"`。
2. **硬过滤**：从 tools JSON 里删除 `exec_command` 和 `agent_delegate` 两条；这是 `run_non_interactive` 内的代码，不是子 agent 的 system prompt 教它别用。
3. 如果 `DELEGATION_DEPTH >= 2`，再往 system prompt 注入一段"Do not call `agent_delegate` in this context" 兜底。
4. 用 `jj push` 构造 messages：`[{role:system, content:...}, {role:user, content:"$TASK\n\n(topic: $TOPIC)"}]`，`MAX_NON_INTERACTIVE_ITERS=5` 次内循环。
5. 拿到 final assistant 消息，写一行 `reply_to=$PARENT_ID` 到 blackboard，`exit 0`；超时/出错写一行 `payload="[error] ..."` 然后 `exit 1`。

**安全模型**：硬过滤在工具层，prompt 注入在模型层，纵深防御。两次都失败才会让子 agent 拿到 `exec_command`，概率极低。

**深度上限**：`DELEGATION_DEPTH=0` 父级 → `1` 子级 → 第二次再 `agent_delegate` 时已经是 `2`，被脚本拦截。这意味着"父 → 子 → 孙子" 不可能，递归最多 2 层。

**长度上限**：task ≤ 8000 字，reply ≤ 8000 字，120s 墙钟——避免长跑爆资源。

### 13.8 coordinator 示例

直接问 coordinator：

```
You> /agent coordinator
You> 在当前目录里跑一次安全审计，结果写到 board 主题 audit-001
```

coordinator 内部大概这么走（实际由模型决策）：

1. 调 `agent_list` 知道有哪些 persona。
2. 调 `agent_delegate(agent="code-reviewer", task="列出 .data/ 和 tools/ 下的潜在安全风险",
   topic="audit-001:review")` → 拿到 read-only review 结果。
3. 调 `agent_delegate(agent="default", task="把 review 结果里的 BLOCKER 项汇总成 markdown",
   topic="audit-001:summarize")` → 拿到 markdown 报告。
4. 把最终报告通过 `board_write` 写到 `audit-001` 主题，reply_to 指向上一步。

人侧可以 `/board audit-001` 看到完整时间线：`[code-reviewer 的发现] → [default 写的 markdown] → [coordinator 的总结]`。

### 13.9 `/hist` 的四种模式

`/hist` 现在有四种用法，按"摘要 → 完整 → 单条摘要 → 单条完整"递进：

```
You> /hist              # 摘要：每条消息截 60 字符，tool_call 只显示 result 长度
You> /hist full         # 完整：每条 message 完整 content / raw_input / thinking
                        #       + 每条 tool_call 完整 arguments 和 result
You> /hist 114          # 单条（_hist_one 风格）：id=114 + 关联 tool_call
You> /hist full 114     # 单条（_hist_full 风格）：id=114 的 `--- #id role= ...` 块
                        #                          + 关联 tool_call
```

`/hist full [N]` 用 `---` 分隔每条 message，用 `  tool: <name>  id=<call_id>` 缩进
显示 tool_call，缺名占位 `(unnamed)`。`/hist full` 没有 / 找不到时
打印 `no message with id=N` 并继续接受下一条命令（不会因为 `set -e` 中断 REPL）；
非数字 id 打印 `id must be numeric`。

**为什么有 `full <id>` 和 `<id>` 两种单条模式？** `_hist_one` 走 `== message #N ==`
+ 空行分隔的紧凑格式；`_hist_full` 走 `--- #N role=... ---` 块状格式，
块内字段 `[content]` / `[raw_input]` / `[thinking]` 带方括号标签。两种风格
分别服务"快速看一眼"和"复制粘贴到 bug 报告"两个场景，按需选。

要看别的 agent 的历史依然要先 `/agent <name>` 切过去——没有跨 agent 的
`/hist <agent>` 命令，避免一次性 SQL 跨多库带来的复杂度。

### 13.10 写在最后

整套多 agent 机制增加的主代码量大约 250 行，分布在 8 个新工具脚本和 `ai-agent.sh` 的几个函数里。设计原则和 v0.0.6 一脉相承：

- **每个机制只做一件事**：`load_tools` 合并、blackboard 写、agent 委派，三件事分开。
- **尽量复用现有基元**：委派其实就是"在 fork 的子进程里跑主脚本的 NON_INTERACTIVE 入口"，没造独立运行时。
- **安全靠工具层，不靠 prompt**：基线 `exec_command` 和 `agent_delegate` 在子进程里直接被过滤，prompt 只能做兜底。

如果你要扩展这套系统，建议先问三个问题：

1. 新 agent 需要哪些基线工具之外的工具？（写 `agents/<name>/tools/`）
2. 它需要和谁通信？走 blackboard 的哪个 topic？
3. 它的输出需要回写还是直接返给调用方？

回答清楚这三个问题，新 agent 接入通常 5 分钟内能完成。

### 13.11 REPL 提示符与误操作防护

主循环的 `read -e -p` 不再写死 `\e[1;32mYou>\e[0m`，而是用 `_agent_prompt`
函数渲染当前 agent 状态：

| 当前 agent | 提示符 | 颜色含义 |
|---|---|---|
| default | `You [default]>` | 绿色 — 默认上下文 |
| code-reviewer | `You [code-reviewer · read-only]>` | 黄色 — 专用 persona |
| coordinator | `You [coordinator · orchestration, planning, delegation]>` | 黄色 — 专用 persona |

`description` 超过 30 字符会被截断并加 `…`，所以 prompt 不会撑爆屏幕。
颜色切换（绿→黄）就是"你在一个非默认上下文里"的视觉信号；用户忘记
`/agent` 切回去时一眼就能看到。

`_agent_prompt` 在每次 `read` 时调用，所以 `/agent` 切换后下一条命令的
提示符立即变色，不需要重启 REPL。

---

## 第 14 章：AI Coding Team

第 13 章讲了怎么手动切 agent、怎么用 blackboard 通信、怎么用 `agent_delegate`
把任务扔给另一个 agent 跑。这些是**机制**——但要真正在项目上演示一次"开需求
→ 出方案 → 写代码 → 写测试 → 改文档 → 复盘"的全流程，coordinator 必须
能**自驱**而不是每步等人按。本章讲怎么把这套机制组装成一个能自跑的团队。

### 14.1 从手动到自驱：还差什么

第 13 章的 coordinator 用法是**手动协作**——人切到 coordinator，告诉它
"做 X"，它自己调度。如果想"coordinator 自己开一个 session，跑完整
流程，期间人不动"还需要三个东西：

1. **任务队列**：一个持久化、跨进程的"待办"列表，coordinator 写、
   sub-agent 读。
2. **状态机**：每个任务有生命周期（`pending` → `claimed` → `in_progress` →
   `done`），并支持依赖（"test 任务要等 code 任务 done"）。
3. **派发循环**：coordinator 反复做"找下一个 ready 任务 → 派给对应
   agent → 等 reply → 标 done"这件事，直到所有任务完成。

v0.0.14 加进来的就是这三件：统一 `.data/ai-agent.db` 里的 `tasks` /
`task_events` / `team_state` 三表（任务队列 + 状态机）+ 6 个
task 工具（CRUD 接口）+ 4 个 `/team` 子命令（派发循环）。

### 14.2 任务表 schema

`.data/ai-agent.db` 里跟 team 相关的三个表（详细在 `team/schema.sql`）：

```sql
CREATE TABLE tasks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    type        TEXT    NOT NULL CHECK (type IN ('spec','design','code','review','test','docs','meta')),
    status      TEXT    NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','ready','claimed','in_progress','done','blocked','cancelled')),
    title       TEXT    NOT NULL,
    description TEXT    NOT NULL DEFAULT '',
    depends_on  TEXT    NOT NULL DEFAULT '',  -- CSV of task ids
    assigned_to TEXT    NOT NULL DEFAULT '',  -- agent name
    created_at  TEXT    DEFAULT (datetime('now')),
    updated_at  TEXT    DEFAULT (datetime('now'))
);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_type   ON tasks(type);

CREATE TABLE task_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    event      TEXT    NOT NULL,           -- 'created' | 'claimed' | 'status' | 'reply' | 'done'
    agent      TEXT    NOT NULL DEFAULT '',
    detail     TEXT    NOT NULL DEFAULT '',
    created_at TEXT    DEFAULT (datetime('now'))
);
CREATE INDEX idx_events_task ON task_events(task_id, id);

CREATE TABLE team_state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
);
```

字段选择上有几个值得说明的取舍：

- **6 种 `type` 对应 6 种角色**（`spec/design/code/review/test/docs` +
  `meta` 给 coordinator 自己的杂务）。`type` 不直接绑 agent，而是用
  `_team_agent_for_type` 这个映射做查表——以后加新 agent 不用动 schema。
- **`depends_on` 用 CSV 字符串**而不是单独的关系表。任务依赖通常
  是"我得等 1-3 个上游任务"，加张关系表是过度设计。`task_list` 算
  `ready=1` 时用 `LIKE '%,<id>,%'` 反向查"有谁依赖我" + `NOT EXISTS`
  子查询过滤"我依赖的人还没 done"。
- **7 种 `status`**：把 `ready` 和 `pending` 拆开——`pending` 是"被
  创建了但有依赖"，`ready` 是"无依赖可派发"；这样 SQL 过滤 ready
  任务不用每次重算依赖图。`claimed` / `in_progress` 进一步拆开是为了
  audit trail（什么时候谁 claim 的，进展如何）。
- **`task_events` 是 append-only audit trail**。`task_done` /
  `task_claim` / `task_update` 每次状态切换都写一行事件，可以从
  `task_show` 一路 replay 出整个任务的生老病死。

### 14.3 任务工具一览

| 工具 | 输入 | 行为 |
|------|------|------|
| `task_create` | `type, title, description?, depends_on?` | `INSERT`；返回 `{id}` |
| `task_list` | `status?` (or `ready`), `type?`, `limit?` | `SELECT` + 过滤；`ready=1` 时用 NOT EXISTS 子查询 |
| `task_claim` | `task_id` | 检查 `status='ready'`，设为 `claimed`，记 `assigned_to=$AGENT_NAME`；并发保护用单条 `UPDATE ... WHERE status='ready'` |
| `task_update` | `task_id, status?` (or `assigned_to?` or `description?`) | 写 `task_events`，更新字段；不允许多 status 互转（如 `done` → `pending` 拒绝） |
| `task_done` | `task_id, result?` | 设为 `done`，写 `result` 到 `task_events`；只允许 `assigned_to` 自己或 coordinator 调用 |
| `task_show` | `task_id` | 任务本体 + 全 `task_events` 的 JSON |

`task_show` 的实现值得一提：它**不**用一个 `jq` 把整行 SQL result 包装
成 JSON（那样 title 里有 `"` 就破坏），而是**逐字段查** `tasks`，再**逐
事件查** `task_events`，每个文本字段都用 `jq -Rsr '@json'` 转义成 JSON
字面量，最后再 `jq -s '{task:.[0], events:.[1:]}'` 拼装。这一套下来
title / description / result 里有任意字符（`"`、换行、控制字符）都能
原样 round-trip。

### 14.4 REPL 任务命令

```
/tasks                       # 按 status 分组的计数
/tasks pending                # 列出 status=pending 的任务
/tasks ready                  # 列出 ready=1 的任务（可派发）
/tasks done                   # 历史
/tasks code                   # 按 type 过滤
/tasks 5                      # 单条（等于 /task 5）
/task 5                       # 单条详情：id, type, status, title, description, depends_on, assigned_to, events
```

`/tasks` 默认按 status 分组（done / in_progress / claimed / ready /
pending / blocked / cancelled），每组下用紧凑一行展示。
`/task <id>` 是 `task_show` 的人检视入口——把 `task_events` 按时间顺序
打印，事件之间用 `───` 分隔，事件本身一行 `event agent=... detail=...`。

### 14.5 `/team` 派发循环

`/team` 是 coordinator 的"开始/下一步/状态/停止/清空"五件套：

```
/team                  # = /team status
/team status           # 当前 goal + 任务分布 + 下一步预览
/team start <goal>     # 开新目标
/team next             # 派发下一个 ready 任务
/team stop             # 清空 goal（保留任务）
/team clear [-y]       # 软取消：非 done 任务翻成 'cancelled' + 清 goal
```

**`/team start <goal>` 做的事**：

1. 写 `team_state.current_goal = <goal>` + `current_goal_id = 0`（先占位）。
2. 创建 1 个 `spec` 任务（type=spec, title="Goal: <goal>", status=pending）。
3. **把 spec 任务标 ready**（它没有依赖）。
4. 调 `agent_delegate(agent="pm", task="<goal 的完整描述>...Create
   sub-tasks for each phase of the work, using `task_create`...", topic="team:start")`。
5. PM 跑完，在 blackboard 写一行 `team:start` 的 reply。
6. 父进程从 reply 读出 PM 的总结（"我创建了 5 个任务：2 个 design + 1 个
   code + 1 个 test + 1 个 docs"），把这个总结写进 spec 任务的 `description`，
   再把 spec 任务标 `done`，最后把 `current_goal_id` 改成 spec 的 id。

**`/team next` 做的事**：

1. 读 `team_state.current_goal`；空就打印 `no active goal` 并返回。
2. `task_list status=ready limit=1`——只取一个 task，保持**manual-but-scripted** 节奏。
3. 查不到 ready 任务时：再 `task_list` 看是不是真的全 done，是就
   打印 `all tasks done. /team stop to clear goal.`。
4. 拿到 task 后：
   - 用 `_team_agent_for_type <type>` 算出要派给谁。
   - 调 `task_claim <id>`（设 `assigned_to=coordinator`，避免两个
     `/team next` 并发跑时重复派）。
   - 调 `agent_delegate(agent=<agent>, task="<title>\n<description>",
     topic="task:<id>")`。
   - 父进程轮询 blackboard 等 reply，300s 超时。
5. 拿到 reply：把 reply 截断到 4000 字写进 `task_events.detail`，
   调 `task_done <id>`。
6. **fallback**：子 agent 跑了 300s 没写 reply（多半 LLM 端
   `parse error: error.InvalidJson`），父进程也标 done，
   `detail="(no board reply from <agent>)"`，这样依赖任务能继续走。

**`/team stop` 做的事**：清 `team_state.current_goal` 和
`current_goal_id`。**不**删 tasks——历史是 audit trail，留着。

**`/team clear [-y|--yes]` 做的事**：**软取消**——把 `status` 为
`pending` / `claimed` / `in_progress` / `review` / `blocked` 的任务翻成
`cancelled`，清掉 `team_state` 里的 `current_goal` / `current_goal_id`，
重置 `sqlite_sequence`（让新 task 从 1 开始）。**`done` 任务保持原样**——
它们是已完成的工作，翻成 cancelled 是误导。**`task_events` 行不删**
——审计 trail 完整保留。

无 flag 时，若 stdin 是 tty 且有非 done 任务，提示 `cancel N task(s)? [y/N]`，
回车默认 N（不取消）。`-y` / `--yes` 跳过 prompt。脚本化场景（管道喂入）
自动跳过 prompt（`-t 0` 假）。

**彻底抹掉 team 数据的方法**：`clear` 是软操作，不删行。要真删所有审计，shell 里
跑 `rm -f .data/ai-agent.db`——下次启动 `init_db` 会自动从 `team/schema.sql` 重建。

幂等：所有任务都是 done 或 cancelled、goal 也空时，`/team clear` 输出
`team already empty (no tasks, no goal)`。

典型用途：跑完一次 demo，想再开一轮新 goal、又不想被旧任务污染 ready 队列
——`clear`（旧任务变 cancelled，不再算 ready，但 history 还在可 `/hist`）→ `start`。

### 14.6 manual-but-scripted 编排风格

`/team next` 一次只派一个任务。这个**故意**的限制有几层考虑：

- **可调试**：派 5 个任务并发跑的时候，trace 会交错；一次一个，
  你能清楚看到"task #2 派给 architect → architect 跑 47s → reply 写了
  1200 字 → task #2 标 done → task #3 派给 developer"。
- **可重放**：`/team next` 是幂等的——失败重跑不会重复创建任务
  （`task_claim` 做了 `WHERE status='ready'` 保护）。
- **不触发并行**：bash 没有进程池；想要并行得用 GNU parallel + 多
  个 `/team next` 后台，复杂度爆炸。一次一个能跑就行。
- **避免 LLM 端雪崩**：连续派 5 个 `agent_delegate` 等于同时打 5 个
  HTTP 请求到 LLM 端，token 限流很容易爆。串行派让后端有时间歇。

如果以后需要"全速派发"，最简单的扩展是把 `/team next` 加一个
`/team next all` 子命令，循环里 `task_claim` + `agent_delegate &`
后端跑。当前 v0.0.14 不带——保持**简单能跑**。

### 14.7 type→agent 映射

`_team_agent_for_type` 是一个 8 行的 case：

| task type | 派给 |
|---|---|
| `spec` | `pm` |
| `design` | `architect` |
| `code` | `developer` |
| `review` | `code-reviewer` |
| `test` | `tester` |
| `docs` | `docs` |
| `meta` | `coordinator` |

这映射是 `/team next` 的核心——它把"task 的领域"翻译成"谁来干"。

加新角色（比如 `security-auditor`）的步骤：写 `agents/security-auditor/
system.md`（带 `type:security` tag）→ 在 `_team_agent_for_type` 加一行
`security → security-auditor` → 在 task 表的 CHECK 约束加 `'security'`。
三处改动，10 分钟内能做完。

### 14.8 6 个新 persona 一览

每个 persona 写在自己 `agents/<name>/system.md`，frontmatter 含
`type:<role>` tag 让 `/agents @<type>` 能找到它。

- **`pm`** (spec, planning, type:pm) — 接到 goal 后：clarify（问清楚含糊点）→
  spec（写出"做什么/不做什么/验收标准"三段）→ prioritize（拆出 3-7
  个子任务，每个带 `type`、`title`、`description`，用 `task_create` 入队）。
  **不写代码**，只产出"清单 + 验收"。
- **`architect`** (design, type:design) — 接到一个 design 任务后：先读
  相关源码 → 输出 contract（接口签名/输入输出/error 路径）+ schema
  （新表/新字段/迁移）+ test plan（先列要测的边界条件）。**不写实现代码**，
  只产出"设计 + 测试用例大纲"。
- **`developer`** (code, type:code) — 接到 code 任务：读 architect 的设计 →
  写实现 + 最小测试 → 跑一遍确认不破坏现有功能 → 在 board 写"完成 +
  哪些文件动了"。
- **`tester`** (test, type:test) — 接到 test 任务：黑盒——只看任务描述和
  最终行为，不看 developer 的实现 → 跑现有测试 + 写新边界 case。
  **不信任**，自己造失败用例。
- **`code-reviewer`** (review, read-only) — 第 13 章已有的 read-only
  persona；接到 review 任务：通读 diff + 列 5 类问题（correctness / security
  / readability / test coverage / doc），每条带 file:line 引用。**不允许**
  `exec_command`（基线工具被 `tools/exec_command.{json,sh}` 覆盖成
  `success:false`）。
- **`docs`** (docs, type:docs) — 接到 docs 任务：把这次改动同步到 README /
  book.md / CHANGELOG.md；如果是新功能，book.md 加一节"用法"；CHANGELOG
  写到对应 unreleased 段。
- **`coordinator`** (orchestration, planning, delegation, type:meta) —
  已有 persona；现在还多了 `type:meta` 让它能 own "团队总结" / "里程碑
  收尾"这类杂务任务。

每个 persona 的 system.md 都有一句"Do not use `exec_command`"或
"Use `task_create` to enqueue your deliverables"——具体的"调用什么
工具"指引。**但工具层的硬约束**（sub-agent 跑时 `exec_command` +
`agent_delegate` 被脚本硬过滤掉）才是底线，prompt 只能做兜底。

### 14.9 端到端 demo 跟踪

把"在 zig-cos 上加一个 `/tasks` 命令"作为 demo 目标跑一遍的实际 trace：

**Step 1: PM 拆任务**（`/team start "add /tasks command"`）

```
dispatching task #1 (type=spec, agent=pm): Goal: add /tasks command
  PM: "I'll break this down into 5 phases:
        1. design the command syntax and data model (design)
        2. implement the parsing + dispatch (code)
        3. add test cases (test)
        4. update README + book.md (docs)
        5. final code review (review)"
  -> task_create(type=design, title="Design /tasks command structure")
  -> task_create(type=code, title="Implement /tasks in ai-agent.sh", depends_on="2")
  -> task_create(type=test, title="Test /tasks in REPL", depends_on="3")
  -> task_create(type=docs, title="Update README with /tasks", depends_on="3")
  -> task_create(type=review, title="Review /tasks implementation", depends_on="3,4,5")
  board: pm wrote 5 sub-tasks + spec task marked done
```

**Step 2: 派发循环**（5 次 `/team next`）

```
/team next
  ready=1: #2 design "Design /tasks command structure"
  -> agent_delegate(architect, "Design the /tasks command and task DB schema")
  architect: reads ai-agent.sh, returns 3-paragraph design
  -> task_done #2 (by architect)

/team next
  ready=1: #3 code "Implement /tasks in ai-agent.sh"  (depends on #2 done)
  -> agent_delegate(developer, ...)
  developer: edits ai-agent.sh, adds /tasks case, runs test_final.sh
  -> task_done #3 (by developer)

/team next
  ready=1: #4 test "Test /tasks in REPL"  (depends on #3 done)
  -> agent_delegate(tester, ...)
  tester: writes 3 new test cases in /tmp/test_final.sh, runs them
  -> task_done #4 (by tester)

/team next
  ready=1: #5 docs "Update README with /tasks"  (depends on #3 done)
  -> agent_delegate(docs, ...)
  docs: edits README.md, book.md, CHANGELOG.md
  -> task_done #5 (by docs)

/team next
  ready=1: #6 review "Review /tasks implementation"  (depends on #3,#4,#5 all done)
  -> agent_delegate(code-reviewer, ...)
  code-reviewer: 5 categories of feedback, no BLOCKERs
  -> task_done #6 (by code-reviewer)

/team next
  ready=0: all tasks done
  -> "all tasks done. /team stop to clear goal."
```

总耗时大概 3-5 分钟（每轮 `agent_delegate` 实际跑 30-60s，串行），
**全程无人工介入**。

### 14.10 故障模式与兜底

跑 demo 时遇到的几个故障模式 + 怎么处理：

- **LLM 端 `parse error: error.InvalidJson`**：模型偶尔返回的 JSON
  body 少个 `]`。`run_non_interactive` catch 住，write 一行
  `[error] parse error` 的 reply，照样标 done。**不**死循环重试——
  一次失败就跳过，让依赖任务继续。
- **PM 拆出来 24 个重复任务**：模型有时把"design"+"design"+"design"
  当成 3 个独立任务拆出来。`task_create` 不去重（DB 层不该有"语义
  去重"），但 `/team` 派发时会按 type 排，把同样的 design 一个个
  派给 architect，architect 看到 `depends_on` 链会发现重复。
  **修法**：PM 的 prompt 现在显式说"create 3-7 sub-tasks, one per
  phase, no duplicates"。
- **agent 不写 board reply**：sub-agent 跑完最后一轮 ReAct 但没
  显式 `board_write`，父进程 300s 超时。`/team next` fallback 标
  done + `(no board reply from <agent>)`——下一轮 `task_list ready`
  就能继续。**修法**：`_team_start` 在 PM 的 prompt 里显式
  "After creating all tasks, write a summary to the blackboard"，
  `_team_next` 在 agent prompt 里也加这句。
- **`task_create` 报 "insert failed: no such table: tasks"**：
  PM 跑在 forked 子进程里，旧版 `TEAM_DB_PATH` 没透传过去，sub-agent
  默认找错位置。**修法**：`agent_delegate.sh` 在 fork 前 export
  `AI_AGENT_DB=$PARENT_AI_AGENT_DB`，sub-agent 的 env 自动继承
  （v0.1.0+ 统一为一个 var 之后这个坑就只剩一个变量了）。

### 14.11 写在最后

整套 AI Coding Team 的代码量：

- `team/schema.sql`：30 行 SQL
- 6 个 task 工具 × 2 文件（.json + .sh）：~500 行
- `ai-agent.sh` 新增：~250 行（5 个 `_team_*` 函数 + `/team` case 分支 + 3 个 `_task_*` helper）
- 6 个新 persona × 1 system.md：~250 行

总 ~1000 行，换来一个**自跑**的 PM / architect / developer / tester /
code-reviewer / docs / coordinator 七人团队，能在 zig-cos 自身上把
"加一个新功能"这件事从 goal 跑到 changelog 写完。

设计原则还是第 13 章那三条（**单一职责 / 复用基元 / 工具层硬约束**），
外加一条：**自驱用 DB 队列，不用内存消息**——session 没了任务还在，
明天起来 `/team next` 继续派。

### 14.12 测试套件

21 组、96 项断言的 LLM-free 套件入仓在 `tests/test.sh`（`tests/README.md`
有完整说明）。覆盖：工具 manifest JSON / `.sh` 语法 / REPL 命令接线 /
blackboard roundtrip / task 队列 / 7 个 persona 切换 / `/team` 工作流。
跑：

```bash
bash tests/test.sh    # 或 ./tests/test.sh（已 chmod +x）
```

**不**测的：真实 ReAct 循环（要 LLM 后端）—— 那是 §14.9 demo 的范围。

---

## 附录

### A. 函数参考

| 函数 | 作用 | 关键代码行 |
|------|------|-----------|
| `init_db()` | 初始化 SQLite 数据库 | 51-63 |
| `sql()` | 执行 SQL 查询 | 65 |
| `add_message()` | 添加消息到数据库 | 67-75 |
| `save_assistant_tool_call()` | 保存 AI 的工具调用 | 77-85 |
| `save_tool_result()` | 保存工具执行结果 | 87-92 |
| `help()` | 显示帮助信息 | 94-109 |
| `load_history()` | 从数据库加载历史 | 117-128 |
| `prune_history()` | 修剪过长的历史 | 130-137 |
| `load_tools()` | 加载工具配置 | 139-145 |
| `handle_tool_call()` | 处理单个工具调用 | 147-175 |
| `build_base_messages()` | 构建消息体（不含当前输入） | 177-186 |
| `build_messages()` | 构建完整消息体 | 188-193 |
| `process_input()` | 处理用户输入（/命令） | 195-228 |
| `cleanup_orphan_tc()` | 清理孤立工具调用 | 230-252 |

### B. 环境变量参考

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `API_KEY` | (从 `win/ds` 获取) | DeepSeek API 密钥 |
| `MODEL` | `deepseek-v4-flash` | 模型名称 |
| `API_URL` | `https://api.deepseek.com/chat/completions` | API 端点 |
| `DATA_DIR` | `.data` | 数据存储目录 |
| `MAX_HISTORY` | `40` | 最大历史消息数 |

### C. 目录结构

```
ai-agent/
├── ai-agent.sh          # 主脚本
├── SYSTEM_PROMPT.md     # 系统提示词
├── .data/
│   ├── ai-agent.db      # 统一 SQLite（chat + board + tasks）
│   ├── tools.json       # 工具定义
│   └── .input_history   # readline 历史
└── .tmp/
    └── last-response.txt # 上次响应缓存
```

---

## 结语

ai-agent.sh 是一个优雅的工程范例——用 ~1330 行 Bash 脚本，实现了单 agent 工具调用、多 agent 编排、以及 7 人 AI Coding Team 任务派发三套机制。它证明了：

1. **简单工具也能做出强大的东西** —— Bash + curl + sqlite3 + jq + jj，四个小工具的组合
2. **Tool Calling 是 AI 落地的关键** —— 让 AI 不仅能说，还能做
3. **多 agent 协作不需要框架** —— 黑板 + persona 隔离 + 进程委派，~250 行新代码
4. **透明即安全** —— 全部代码都在一个脚本里，每一行都可审查、可理解、可修改

希望本书能帮助你掌握 ai-agent.sh，并激发你构建更强大的 AI 工具。

Happy Hacking!

---

*字数：约 25,000 字 | 完成于 2026 年 6 月*
