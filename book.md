# 《AI Agent Shell 实战指南》—— 从零掌握 ai-agent.sh

## 前言

在人工智能飞速发展的今天，AI 编程助手已成为开发者离不开的工具。但大多数 AI 助手只停留在"问答"层面，无法真正操作你的代码库、执行命令或读取文件。

**ai-agent.sh** 打破了这个局限——它仅用 394 行 Bash 脚本，就构建了一个完整的 AI Agent 终端环境。它连接 DeepSeek 大模型 API，让你的终端变成一个**能读、能搜、能执行、能自主调用工具**的智能代理。

本书将带你从零开始，全面掌握 ai-agent.sh 的使用、原理与扩展。

---

## 第 1 章：初识 ai-agent.sh

### 1.1 什么是 ai-agent.sh

ai-agent.sh 是一个基于 Bash 脚本的 AI Agent 终端程序，它：

- 通过 API 连接 **DeepSeek** 大模型
- 在终端中提供交互式对话界面
- 支持 **工具调用**（Tool Calling）：读取文件、搜索代码、执行命令
- 使用 **SQLite** 持久化对话历史
- 所有功能封装在 **单个脚本文件**（394 行）中

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
  - chat.db（对话历史数据库）
  - tools.json（工具定义）
```

### 3.2 多轮对话

ai-agent.sh 会记住上下文。你可以连续提问：

```
You> 这个脚本有多少行？
Agent> ai-agent.sh 共 394 行。

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

所有消息存储在 SQLite 数据库 `.data/chat.db` 的 `messages` 表中：

```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    role TEXT NOT NULL,         -- system / user / assistant / tool
    content TEXT,               -- 消息内容
    user_input TEXT,            -- 用户的原始输入（仅 user 消息）
    tool_calls TEXT,            -- 工具调用 JSON（仅 assistant 消息）
    tool_call_id TEXT,          -- 工具调用 ID（仅 tool 消息）
    created_at TEXT DEFAULT (datetime(now))
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

`MAX_HISTORY=40` 限制最大消息数。超过时删除最早的消息：

```bash
prune_history() {
    count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages")
    if [[ $count -gt $MAX_HISTORY ]]; then
        remove=$((count - MAX_HISTORY))
        sqlite3 "$DB_PATH" "DELETE FROM messages WHERE id IN 
            (SELECT id FROM messages ORDER BY id LIMIT $remove)"
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

如果数据库出现问题，可以安全删除：

```bash
rm -rf .data/chat.db
```

下次启动时会自动重建。

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
│   ├── chat.db          # 对话历史 SQLite
│   ├── tools.json       # 工具定义
│   └── .input_history   # readline 历史
└── .tmp/
    └── last-response.txt # 上次响应缓存
```

---

## 结语

ai-agent.sh 是一个优雅的工程范例——用不到 400 行 Bash 脚本，实现了 AI Agent 的核心功能。它证明了：

1. **简单工具也能做出强大的东西** —— Bash + curl + sqlite3 + jq + jj，四个小工具的组合
2. **Tool Calling 是 AI 落地的关键** —— 让 AI 不仅能说，还能做
3. **透明即安全** —— 394 行代码，每一行都可审查、可理解、可修改

希望本书能帮助你掌握 ai-agent.sh，并激发你构建更强大的 AI 工具。

Happy Hacking!

---

*字数：约 15,000 字 | 完成于 2025 年*
