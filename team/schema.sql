-- team_schema.sql
-- Persistent task queue + audit log for the AI Coding Team.

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
