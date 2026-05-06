# DESIGN — MyndAIX Control-Plane Daemon

**Status:** DRAFT — pending Oracle Phase 0 review
**Author:** Mack
**Date:** 2026-04-21
**Parent decisions:** `docs/research/boardroom-rebuild-20260421.md`, `docs/research/audit_20260421.md`

---

## Problem

MyndAIX has 5+ execution surfaces that can independently dispatch agent work (inbox file drop, PostToolUse hooks, watcher crons, `dispatch.sh`, `auto-router`, `trigger-review`). No single authority; no single view. Symptoms:

- "Lobster looping in Discord" was actually an auto-review PostToolUse hook posting P0/P1 alerts into command-center. Not an LLM bug.
- `lobster-monitor.sh` ran uncommitted in production for weeks.
- Enforcement hook blocked its own dispatches because `systems-check.sh` never wrote the marker it required.
- `dispatch.sh` emits task types `PROTOCOL.md` doesn't define.
- Findings from KilaBz reviews rot — nothing tracks whether a P1 finding got fixed.

Root cause: **no single dispatch authority; no single source of truth for task state.**

## Objective

Replace all dispatch surfaces with a single daemon that owns task lifecycle. Every agent interaction — hook event, watcher observation, Discord message, inbox drop — becomes an **event reported to the daemon**. Only the daemon mutates task state. Only the daemon dispatches work.

## Non-Goals

- Rewriting OpenClaw integration (keep as external service).
- Replacing Syncthing (it works; the issue was what was synced, not the sync).
- Right-sizing the agent fleet (solve control plane first).
- Kafka, RabbitMQ, SQLite, or any "real" message queue. File-based inspectability is an operating constraint — `ls`, `cat`, `grep` must stay as debugging tools.

## Core Invariants (ranked by blast radius)

1. **Single dispatch authority.** The daemon is the only process allowed to mutate task state directories or dispatch agent work. Hooks, watchers, Discord listeners are **event sources**; they report events and stop. *Detection signal:* any process other than the daemon writing to `state/tasks/active/` = alarm.

2. **Operator-alert channel separation at protocol.** Two Discord webhooks. `$DISCORD_WEBHOOK_OPS` for human ↔ Lobster. `$DISCORD_WEBHOOK_ALERTS` for daemon-authored automation notices. An auto-generated message posted to the ops webhook is a contract violation that the daemon logs and drops. *Detection signal:* `from != "operator" && channel == "ops"` = alarm.

3. **File inspectability preserved.** Task state lives in per-task markdown files that move between directories. JSONL audit log records every state transition. No binary storage, no SQLite, no database. *Detection signal:* if a human cannot answer "what is task X doing?" by `cat`-ing one file = design failure.

## Target Architecture

Five components, no more:

| Component | Owner | Authority | Failure signal |
|-----------|-------|-----------|----------------|
| **Daemon** (bash, launchd-managed) | Jefe | Only process that mutates `state/tasks/` and writes to `state/audit.jsonl`. Only dispatcher. | daemon exits unexpectedly; heartbeat stale >60s; any other process writes to state dirs |
| **Event ingesters** (hooks, watchers, Discord listener) | Jefe | Observers only. Write events to `state/events/incoming/`; never mutate task state. | event file unclaimed by daemon >30s = daemon down |
| **Agent workers** (Lobster, Mack, Mini, KilaBz, etc.) | Jefe | Pull work from daemon's outbound spool (`state/tasks/active/<agent>/`); write results to `state/tasks/done/<agent>/`. | no heartbeat from agent >5min while active task exists |
| **Operator interface** (`#command-center`, CLI `mx status`) | Jefe | Read-only view of daemon state + manual task submission via `state/events/incoming/`. | cannot render current task state = daemon down |
| **Alert sink** (`#alerts`, `state/audit.jsonl`) | Daemon | Daemon-authored only. Operator reads, never writes. | message in `#alerts` with `from != "daemon"` = protocol violation |

## Directory State Machine

```
state/
├── events/
│   ├── incoming/         # event sources drop here; daemon claims
│   └── processed/        # daemon moves here after ingestion
├── tasks/
│   ├── pending/          # daemon has claimed event, waiting for worker slot
│   ├── active/<agent>/   # dispatched to agent; agent reads here
│   └── done/<agent>/     # worker moved here on completion
│   └── failed/<agent>/   # worker moved here on failure; requires triage
├── findings/             # reviewer findings, tracked by state
│   ├── open/             # finding from a review; not yet addressed
│   ├── fixed/            # finding referenced by a later commit; daemon moves here
│   └── wontfix/          # operator-marked; won't be addressed
├── audit.jsonl           # append-only; one event per state transition
└── daemon.pid            # daemon singleton lock
```

**State transitions (only the daemon performs these):**

```
event received       → events/incoming/<id>.md     → events/processed/<id>.md
event → task         → tasks/pending/<id>.md
pending → dispatched → tasks/active/<agent>/<id>.md
active → done        → tasks/done/<agent>/<id>.md    (agent initiates, daemon audits the move)
active → failed      → tasks/failed/<agent>/<id>.md  (agent initiates, daemon audits the move)
review creates finding → findings/open/<hash>.md
commit references finding → findings/fixed/<hash>.md (via commit-message scan)
```

**Atomicity:** every transition is a filesystem `rename` (atomic on APFS). No partial states possible. The audit log is written AFTER the rename completes so the log reflects actual committed state, not intent.

**Syncthing safety:** every file is either present-in-one-location or moving (rename is atomic). No multi-writer conflicts. Machines observe the same state within Syncthing's sync window. Daemon runs on Mini only; MacBook reads state via Syncthing-synced dir and can submit events.

## Review → Fix Closure

An audit-meta-finding from tonight: findings rot. KilaBz files a P1, nothing ever confirms it got fixed, so the next review files the same P1 again.

The daemon closes this loop:

1. Every finding written to `findings/open/<hash>.md` has a frontmatter field `finding_id`.
2. Every commit message can include `Fixes: <finding_id>`.
3. Daemon watches git commits (post-commit hook = event source). On finding-id reference, daemon moves `findings/open/<hash>.md` → `findings/fixed/<hash>.md` and records the commit SHA.
4. Reviewer (KilaBz, Antman) sees `findings/open/` when reviewing the same file and can acknowledge pre-existing open findings without re-filing.

This is the *structural* version of the persona rule we added tonight ("cross-check current code"). The persona rule is prompt-level; this is state-level.

## Edge Cases

| Case | Handling |
|------|----------|
| Daemon crashes mid-rename | The rename is atomic. On restart, daemon inspects state dirs and resumes. No partial state to reconcile. |
| Two events for the same task id | Daemon rejects duplicate (audit log: `duplicate_event`). Event source must use monotonic ids. |
| Agent never responds to active task | Daemon's watchdog checks heartbeat; after 10 min no activity, moves task to `failed/` with `reason: timeout`. Alert sent. |
| Syncthing conflict on a state dir | Impossible if only the daemon writes — there's one writer per file. A Syncthing conflict = rule violation = alarm. |
| MacBook edits a file in `state/` | Violates invariant #1. Daemon detects via inotify/fswatch, logs alarm, auto-rolls back (Syncthing will re-sync from Mini). |
| Event file malformed | Daemon moves to `events/malformed/` with parse error appended; alerts operator. |
| JSONL audit corruption (partial write) | Daemon reads audit.jsonl on startup with try/except per line. Malformed lines logged, skipped. Appending continues normally. |

## Security Surface

- **Untrusted inputs:** event files from hooks/watchers/Discord. All parsed as DATA (wrapped in `<task_content>` fences before any LLM sees them); never executed as shell; never interpolated into commands.
- **Privileged actions:** the daemon has write access to `state/`, reads `$DISCORD_WEBHOOK_ALERTS` from `~/.myndaix/.secrets`. Nothing else is privileged.
- **Singleton enforcement:** `state/daemon.pid` is an atomic `mkdir` lock, not a PID file. Stale lock after 300s → next start takes over.
- **No `eval`, no untrusted `$()`:** every shell-exec uses `argv` arrays, never string interpolation.

## Observability

- **Heartbeat file:** `state/heartbeat.json` — daemon writes timestamp every 10s.
- **Dead-man's switch:** launchd watchdog restarts daemon if heartbeat stale >60s.
- **`mx status` CLI:** reads state dirs, prints current pending/active/failed tasks. No database; just `ls`.
- **Audit log query:** `grep ' finding_id ' state/audit.jsonl | tail` answers "what happened to finding X?"
- **Prometheus-style health endpoint:** optional Phase 2. Not required for v1.

## Migration (3 weeks, proper pace)

### Week 1 — Observer daemon
- Build daemon in bash. Launchd-managed. State machine read-only at first.
- Deploy alongside current system. Daemon tails existing inbox/outbox/processed dirs. Records transitions to `audit.jsonl`. Dispatches NOTHING.
- **Success metric:** every task that enters the old system appears in `audit.jsonl` within 5s. No false-positive alarms.
- **Rollback:** `launchctl unload`. Old system untouched.

### Week 2 — Single-agent migration
- Day 1: smoke agent. Migrate to the new state machine. Old smoke dispatch path removed. Daemon handles all smoke tasks. Rollback = restore old path.
- Day 3: Lobster. Orchestrator migration is the exact dual-authority bug we're fixing (Advisor 1's reasoning).
- Day 4-7: rest of fleet in risk order — KilaBz, Oracle, Antman, Recon, Harley, Mack.
- Each agent migration is its own day with its own rollback.

### Week 3 — Cleanup
- Delete old paths: `auto-router`, `trigger-review.sh`, redundant `dispatch.sh` code, PostToolUse alert hook (already disabled tonight — now permanently removed).
- Update `PROTOCOL.md` to match implementation (kills protocol drift).
- Stress test: run 1000 synthetic events through daemon. Measure audit log completeness.
- Documentation pass.

## First 3 Moves (what I build tomorrow, day 1)

1. **`daemon.sh` scaffold.** Loop on `state/events/incoming/`, claim + rename to `processed/`, append to `audit.jsonl`. Dispatches nothing, does not touch task dirs. 100 lines of bash.
2. **State directory layout.** Create `state/events/`, `state/tasks/`, `state/findings/`. Write `README.md` in each explaining what belongs there.
3. **Launchd plist.** `ai.myndaix.daemon.plist`, keep-alive, heartbeat to `state/heartbeat.json`.

## Delete / Keep / Defer

**Delete in Week 3:**
- auto-review PostToolUse hook (already disabled tonight — remove file + settings reference)
- `auto-router` (merged into daemon)
- `trigger-review.sh` (merged into daemon)
- Multiple lock mechanisms (replaced by single atomic-mkdir daemon lock)
- `dispatch.sh` (merged into daemon; keep as alias if useful)

**Keep:**
- Markdown as wire format — inspectable, diff-able
- Agent names as operator UX (even when daemon routes by capability under the hood)
- Syncthing + git with commit gate
- Bridge inbox as the event-source path for Discord-originated work (just routed through daemon now)

**Defer:**
- OpenClaw integration rewrite (daemon talks to existing OpenClaw via current interface)
- Right-sizing the agent fleet
- Prometheus metrics / dashboard UI

## Open Questions For Oracle

1. **Event id uniqueness.** Should event ids be UUIDs (universally unique, harder to read) or timestamp-based (readable, requires collision handling under concurrent event sources)? I lean timestamp + 8-char suffix.
2. **Cross-machine write authority.** Daemon runs on Mini. If MacBook becomes Mini's primary (e.g., Mini down), who takes over? Simplest answer: no HA in v1. Only Mini runs daemon. If Mini is down, the system is down. Accept or mitigate?
3. **Failing-agent stuck-task reaper cadence.** I propose 10 min timeout. Too aggressive for slow review tasks (Oracle takes 2-5 min normally), too lenient for fast smoke tasks. Should this be per-agent?
4. **Finding-fix closure loop.** Is watching git commits for `Fixes: <finding_id>` the right mechanism, or should the reviewer explicitly close findings via a new event type?
5. **Migration risk.** Week 2 Day 3 I migrate Lobster — orchestrator — to the new daemon. If the daemon has a subtle bug, Lobster breaks, which means orchestrated recovery also breaks. Should there be a manual smoke-test day before Lobster goes?

## Success Criteria for v1 Launch

- Daemon has been observer-only for 7 days without missing any task transition
- All 8 agents migrated, operating under daemon authority
- Zero auto-generated messages in command-center for 7 consecutive days
- `audit.jsonl` answers any "what happened?" question in < 30s of `grep`
- `findings/open/` is empty for files that have been reviewed twice consecutively with matching fixes committed
- No uncommitted code in production (enforced by pre-dispatch hook, which now has a marker to check against)
