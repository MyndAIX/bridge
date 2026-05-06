-- MyndAIX Bridge — memory.db schema
--
-- Initialize a fresh database with:
--   mkdir -p ~/.myndaix && sqlite3 ~/.myndaix/memory.db < schema.sql
--
-- This file is hand-augmented from the live `.schema` dump on 2026-05-05.
-- Re-extract with: sqlite3 ~/.myndaix/memory.db .schema > schema.sql
-- (then re-add the comments below).
--
-- Tables: memory, patterns, tasks, migration_log
--   memory       — agent-shared knowledge corpus (Upgrade 3)
--   patterns     — auto-promoted recurring outcomes (Upgrade 6)
--   tasks        — SQLite-backed dispatch queue (Upgrade 5)
--   migration_log — bookkeeping for legacy data imports

-- ─── memory ──────────────────────────────────────────────────────────────────
-- Domain-keyed semantic memory shared across agents.
-- Producer/consumer: watchers/lib/knowledge.sh + scripts/dashboard.sh
-- Decay: confidence drifts down over time via the ai.myndaix.memory-decay
-- LaunchAgent so unused entries fade rather than accumulate forever.
CREATE TABLE memory (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT NOT NULL,
    category TEXT NOT NULL,
    content TEXT NOT NULL,
    evidence TEXT,
    source_task_id TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_accessed DATETIME,
    access_count INTEGER DEFAULT 0,
    confidence REAL DEFAULT 1.0,
    deprecated BOOLEAN DEFAULT 0,
    tags TEXT
);
CREATE INDEX idx_memory_domain ON memory(domain);
CREATE INDEX idx_memory_confidence ON memory(confidence);
CREATE INDEX idx_memory_deprecated ON memory(deprecated);
CREATE INDEX idx_memory_domain_active ON memory(domain, deprecated, confidence);

-- ─── patterns ────────────────────────────────────────────────────────────────
-- Occurrence-tracked auto-promotion of recurring outcomes (Upgrade 6).
-- Producer: pattern_record() in watchers/lib/common.sh
-- A pattern auto-promotes at occurrences ≥ 3, becoming a memory entry or
-- a rule (depending on `recommended_type`). The fingerprint is a SHA256 of
-- the salient attributes so repeated occurrences hash to the same row.
CREATE TABLE patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern_type TEXT NOT NULL,
    description TEXT NOT NULL,
    fingerprint TEXT UNIQUE,
    occurrences INTEGER DEFAULT 1,
    first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    promoted BOOLEAN DEFAULT 0,
    promoted_to TEXT,
    promoted_at DATETIME,
    rejected BOOLEAN DEFAULT 0,
    agent TEXT,
    recommended_type TEXT,
    evidence_task_ids TEXT,
    proposal_sent_at DATETIME,
    approved_at DATETIME,
    rejected_at DATETIME,
    approved_by TEXT
);

-- ─── tasks ───────────────────────────────────────────────────────────────────
-- SQLite-backed task queue (Upgrade 5).
-- Atomic claim via UPDATE ... WHERE status = 'pending' RETURNING. Runs in
-- parallel with the file-based inbox/ system; both are valid sources of work
-- as of v1.0. The queue exists primarily for retry/dead-letter mechanics;
-- the inbox/ remains the human-readable source of truth.
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    type            TEXT NOT NULL,
    agent           TEXT NOT NULL,
    priority        INTEGER NOT NULL DEFAULT 5,
    status          TEXT NOT NULL,
    objective       TEXT,
    body            TEXT,
    branch          TEXT,
    success_criteria TEXT,
    dispatched_by   TEXT,
    dispatched_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
    claimed_at      DATETIME,
    completed_at    DATETIME,
    result_summary  TEXT,
    result_path     TEXT,
    error           TEXT,
    retry_count     INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    inbox_file      TEXT
);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_agent_status ON tasks(agent, status);
CREATE INDEX idx_tasks_priority ON tasks(priority);

-- ─── migration_log ───────────────────────────────────────────────────────────
-- Bookkeeping for legacy data imports (e.g. JSONL → memory table migrations).
-- Append-only; safe to leave empty on a fresh install.
CREATE TABLE migration_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_file TEXT NOT NULL,
    entries_imported INTEGER,
    migrated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);
