# MyndAIX System Architecture Audit
**Date:** 2026-03-29 | **Auditor:** Mack | **Status:** Complete, pending Oracle review

---

## Executive Summary

The system works. 7 agents across 2 machines processing tasks autonomously. But it was built organically and shows it: **40% code duplication across watchers, 19MB of unrotated archives, stale locks, orphaned scripts, and a polyglot stack (bash + python3 + ruby + JS) doing the same thing four different ways.**

The routing protocol (daemon) is clean. The execution layer (watchers) needs consolidation. The state management (locks, dedupe, processed) needs cleanup policies.

---

## P0 — Fix This Week

### 1. MCP server agent list is stale
`mcp-bridge-server.js` line 20: `AGENTS = ["lobster", "mack", "antman", "kilabz"]`
Missing: mini, recon, oracle, harley. Can't send messages to 4 of 8 agents via MCP tools.
**Fix:** Update AGENTS array to match daemon.

### 2. Stale lock files (48h+ old)
`locks/auto-router.lock` (PID 78443) and `locks/dispatcher.lock` (PID 7810) haven't updated since Mar 27. Processes are dead.
**Fix:** Clean on daemon startup — remove locks older than 24h.

### 3. Syncthing heartbeat conflicts
10 `daemon-heartbeat.sync-conflict-*` files. Both machines write the heartbeat, Syncthing conflicts.
**Fix:** Namespace heartbeat files per machine: `daemon-heartbeat-macbook.json`, `daemon-heartbeat-mini.json`.

---

## P1 — Fix This Sprint

### 4. Watcher code duplication (40% redundant)
6,090 LOC across 9 watchers. ~200 LOC of identical functions copy-pasted:
- `write_heartbeat()` — 14 lines × 5 watchers
- `log()` — identical × 5+
- `iso_now()`, `safe_slug()` — identical × 5+
- `write_result()` — 25 lines, 95% identical × 5
- `reject_task()` — 10 lines × 5

**Fix:** Extract to `watchers/lib/common.sh`. Each watcher sources it and sets `AGENT_NAME`.

### 5. dispatch.sh has no atomic write
Line 46 writes directly to inbox. If interrupted, partial file left.
**Fix:** Write to temp file, then `mv` (atomic on same filesystem).

### 6. Cost tracking is orphaned
`watchers/lib/cost-tracker.sh` (73 LOC) not sourced by any watcher. `scripts/cost-report.sh` queries `cost-log.jsonl` which does get written by runners.
**Fix:** Either activate cost-tracker.sh in watchers or remove it. The runner-level logging works — the lib is dead code.

### 7. Processed directory grows unbounded (19MB, 1,762 files)
No cleanup policy. No rotation.
**Fix:** Add cleanup to daemon startup or cron: `find processed/ -mtime +30 -delete`.

### 8. Dedupe state grows unbounded (55 marker files)
Empty `.done` files accumulate forever.
**Fix:** Clean markers older than 7 days on daemon startup.

### 9. Notion sync log unbounded (1.9MB)
`logs/notion-sync.log` runs hourly, never rotated.
**Fix:** Add logrotate or truncate on size threshold.

---

## P2 — Fix After Sprint

### 10. Polyglot complexity
Watchers use bash + python3 for JSON/YAML parsing. Python subprocess adds ~100ms per task.
**Fix:** Consolidate to single Python call per task instead of 4 separate `python3 -c` invocations.

### 11. Dead/unclear scripts
| Script | Status |
|--------|--------|
| `bridge-pull.sh` | Dead (3s timeout, no retry, exit 0 always) |
| `bridge-send.sh` | Dead (same) |
| `bridge-sync.sh` | Dead (0B logs for months) |
| `heartbeat-check.sh` | Unclear — no references found |
| `inbox-dispatcher.sh` | Superseded by daemon |
| `gen-task-id.sh` | May be superseded by dispatch.sh |
| `bridge-watchdog.sh` | May be redundant with daemon |

**Fix:** Audit git history, confirm dead, remove.

### 12. Auth watchdog plist references missing script
`com.myndaix.auth-watchdog.plist` points to `scripts/auth-watchdog.sh` which doesn't exist in bridge.
**Fix:** Find the script or remove the plist.

### 13. Daemon alert writes not atomic
Line 208 in daemon writes alert file without temp+rename pattern.
**Fix:** Use same atomic write pattern as the MCP server.

### 14. Implicit lib load order
`chaining.sh` requires `context.sh` and `guardrails.sh` but doesn't explicitly source them. Depends on watcher sourcing in correct order.
**Fix:** Add explicit `source` at top of dependent libs.

---

## P3 — Defer

### 15. Watcher spawn overhead
Daemon spawns watcher via `fork` on every file event. 200ms startup per spawn.
**Defer:** Only matters at high volume. Current volume is fine.

### 16. Context injection vulnerability
`context.sh:inject_context()` strips tags via regex. Could be bypassed with nested/unicode tags.
**Defer:** Low severity — attacker must control result file content.

### 17. Identity detection in MCP server
Hardcoded username check for machine identity. Not scalable.
**Defer:** Works for 2 machines.

---

## Current Data Flows

```
Jefe (Discord/Terminal)
  │
  ├─ Interactive: Mack (MacBook terminal)
  │
  └─ Dispatch: Lobster (OpenClaw on Mini)
       │
       └─ dispatch.sh → inbox/{agent}/
              │
              └─ Daemon (myndaix-daemon.js)
                   │
                   ├─ type: task/review/handoff
                   │    └─ queue/{agent}/ → Watcher executes
                   │         │
                   │         ├─ Result → inbox/lobster/
                   │         ├─ Oracle review → inbox/oracle/ (mandatory)
                   │         └─ Output scan → logs/output-scan.log
                   │
                   └─ type: response/message/status
                        └─ Stays in inbox/{agent}/ (read interactively)
```

---

## Proposed Target Architecture

### Consolidate watchers
```
watchers/
  lib/
    common.sh         ← shared functions (log, heartbeat, result, slug, lock)
    guardrails.sh     ← existing
    context.sh        ← existing
    chaining.sh       ← existing
    self-healing.sh   ← existing
    preflight.sh      ← existing
    parallel.sh       ← existing (mini/oracle only)
    queue.sh          ← existing (mini/oracle only)
  watcher-template.sh ← single template, AGENT_NAME as only variable
  mack-watcher.sh     ← sources template + mack-specific config
  mini-watcher.sh     ← sources template + mini-specific config
  ...
```

Reduces 6,090 LOC to ~4,000. Each watcher becomes ~50 lines of config + template source.

### Clean up state
```
Daemon startup:
  1. Remove locks older than 24h
  2. Remove dedupe markers older than 7d
  3. Remove processed files older than 30d
  4. Truncate logs over 5MB
```

### Remove dead scripts
Delete: `bridge-pull.sh`, `bridge-send.sh`, `bridge-sync.sh`, `inbox-dispatcher.sh`
Investigate: `heartbeat-check.sh`, `gen-task-id.sh`, `bridge-watchdog.sh`

### Namespace per-machine state
- `daemon-heartbeat-macbook.json` / `daemon-heartbeat-mini.json`
- Eliminates Syncthing conflicts on shared state files

---

## Migration Plan

| Step | What | Risk | Time |
|------|------|------|------|
| 1 | Fix MCP agent list | None | 5 min |
| 2 | Clean stale locks | None | 5 min |
| 3 | Namespace heartbeat files | Low | 30 min |
| 4 | Add cleanup to daemon startup | Low | 1 hr |
| 5 | Extract common.sh from watchers | Medium | 2-3 hrs |
| 6 | Remove dead scripts | Low | 30 min |
| 7 | Fix dispatch.sh atomic write | Low | 15 min |
| 8 | Fix daemon alert atomic write | Low | 15 min |

Steps 1-4 can be done today. Steps 5-8 are the sprint work.

---

*Pending Oracle review before implementation.*
