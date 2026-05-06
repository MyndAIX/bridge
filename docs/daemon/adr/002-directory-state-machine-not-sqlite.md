# ADR 002: Directory State Machine, Not SQLite

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** /boardroom (Claude/GPT/Gemini — unanimous rejection of SQLite over Syncthing), Oracle, Perplexity Computer

## Context

Initial rebuild proposal used SQLite WAL as authoritative state. All 3 boardroom advisors rejected this:
- **Advisor 1 (Claude):** file inspectability (`ls`, `cat`, `grep`) is the system's operational soul; SQLite forfeits this
- **Advisor 2 (GPT):** Syncthing replicating WAL files = data corruption risk
- **Advisor 3 (Gemini):** adds operational load on a solo founder

Perplexity Computer later suggested "single-writer SQLite on Mini + file projections to MacBook via Syncthing" as a possible future option, but Jefe explicitly kept Syncthing + file-based state as a hard constraint.

## Decision

Task state lives in per-task JSON files that move between directories via atomic `rename()`:

```
state/pending/ → running/ → done/ | failed/ → processed/
```

Audit log is append-only JSONL (`audit.jsonl`), write-only forensic history, never used for recovery.

## Consequences

- `ls`, `cat`, `grep` remain first-class debugging tools
- Syncthing-safe by construction (atomic rename is atomic per-file)
- JSON Schema validates task record shape; no binary DB format to debug
- Every state transition is a filesystem operation — trivially observable
- No DB dependency, no migration scripts, no backup/restore tooling needed
- Per-machine writes possible only if single-writer rule is enforced (see ADR-004)
- Recovery from daemon crash: re-read state dirs, resume. No replay needed.

## Alternatives Rejected

- **SQLite in WAL mode, synced via Syncthing.** Rejected for WAL+SHM corruption risk.
- **Mini-only SQLite + file projections.** Rejected for v2.0; may reconsider post-v1 if directory patterns prove insufficient. Noted in roadmap.
- **Event log as source of truth with periodic snapshots.** Rejected because reconstruction from audit.jsonl re-introduces the complexity file-based states eliminate.

## Rule

`audit.jsonl` is write-only forensic history. If recovery is ever needed, it comes from `state/` directory contents, NOT from replaying the log.
