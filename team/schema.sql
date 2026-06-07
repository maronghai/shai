-- team_schema.sql
-- Unified schema for the single ai-agent SQLite database
-- (.data/ai-agent.db, overridable via $AI_AGENT_DB).
--
-- This file contains ALL tables in one place:
--   - messages / tool_calls  : per-agent chat history (partitioned by agent_id)
--   - board                  : inter-agent blackboard
--   - tasks / task_events    : team workflow queue + audit trail
--   - team_state             : dispatcher state (current_goal, etc.)
--
-- Per-agent isolation for chat: messages and tool_calls share their table
-- across all personas, but the agent_id column partitions the rows. Each
-- agent's id sequence is independent (computed as MAX(id)+1 per agent).
-- Cross-agent queries are simple SELECTs with no agent_id filter.

-- =======================================================================
-- Chat history (per agent, partitioned by agent_id)
-- =======================================================================

CREATE TABLE IF NOT EXISTS messages (
    agent_id   TEXT NOT NULL DEFAULT 'default',
    id         INTEGER NOT NULL,
    role       TEXT NOT NULL CHECK (role IN ('system','user','assistant')),
    content    TEXT,
    raw_input  TEXT,
    thinking   TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (agent_id, id)
);

CREATE INDEX IF NOT EXISTS idx_messages_agent ON messages(agent_id);
CREATE INDEX IF NOT EXISTS idx_messages_role  ON messages(agent_id, role);

CREATE TABLE IF NOT EXISTS tool_calls (
    agent_id          TEXT NOT NULL DEFAULT 'default',
    id                TEXT NOT NULL,
    message_agent_id  TEXT NOT NULL,
    message_id        INTEGER NOT NULL,
    name              TEXT NOT NULL,
    arguments         TEXT NOT NULL,
    result            TEXT,
    created_at        TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (agent_id, id),
    FOREIGN KEY (message_agent_id, message_id)
        REFERENCES messages(agent_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tool_calls_message
    ON tool_calls(message_agent_id, message_id);
CREATE INDEX IF NOT EXISTS idx_tool_calls_agent
    ON tool_calls(agent_id);

-- =======================================================================
-- Blackboard (inter-agent shared communication)
-- =======================================================================

CREATE TABLE IF NOT EXISTS board (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    agent       TEXT NOT NULL DEFAULT '',
    topic       TEXT NOT NULL,
    payload     TEXT NOT NULL,
    reply_to    INTEGER,
    created_at  TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_board_topic ON board(topic);
CREATE INDEX IF NOT EXISTS idx_board_reply ON board(reply_to);

-- =======================================================================
-- Team workflow (task queue + audit + dispatcher state)
-- =======================================================================

CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    description TEXT,
    type TEXT NOT NULL CHECK (type IN ('spec','design','code','review','test','docs','meta')),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','claimed','in_progress','review','done','blocked','cancelled')),
    assigned_to TEXT,
    depends_on TEXT,           -- comma-separated task ids, e.g. "2,3"
    priority INTEGER DEFAULT 0,
    result TEXT,               -- final output / summary written by task_done
    artifacts TEXT,            -- JSON: list of files / PR refs / etc.
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(type);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned ON tasks(assigned_to);

CREATE TABLE IF NOT EXISTS task_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL,
    agent TEXT,
    event TEXT NOT NULL,        -- 'created','claimed','progress','review','done','blocked','cancelled','comment'
    message TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_events_task ON task_events(task_id);

-- team_state: small key/value store for cross-task session state
-- (current goal, last dispatcher result, etc.)
CREATE TABLE IF NOT EXISTS team_state (
    key   TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT DEFAULT (datetime('now'))
);
