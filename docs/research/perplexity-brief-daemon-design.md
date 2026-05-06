# Brief for Perplexity Computer — MyndAIX Control-Plane Daemon Design Review

**Purpose:** Independent outside review of a production system redesign. Three internal AI advisors and one design reviewer have already weighed in. We're looking for blind spots they missed.

---

## Context in 4 bullets

- **System:** MyndAIX — a solo-founder-built multi-agent AI system. 8 months old. 8 agents (Lobster/orchestrator, Mack/builder, Mini/pipeline, KilaBz/reviewer, Oracle/third-eye, Antman/second-opinion, Recon/research, Harley) communicating via markdown files in an inbox/outbox system synced across MacBook + Mac Mini via Syncthing.
- **Problem:** Built by accretion, not design. Tonight discovered: (1) what looked like "Lobster looping in Discord" was actually an auto-review PostToolUse hook posting alerts into the operator channel; (2) a 517-line watcher script was running in production but never committed; (3) the enforcement hook blocked its own dispatches because its dependency (systems-check.sh) never wrote the marker the hook required; (4) 5+ execution surfaces can independently dispatch agent work — no single control plane.
- **Tonight's work:** Ran a /boardroom with 3 AI advisors (Claude/GPT/Gemini). Unanimous on root cause (single dispatch authority). All 3 rejected my initial SQLite proposal. Converged on directory state machine + JSONL audit log. the user (the founder) decoupled from his YC May 4 deadline to "fix the multi-agent system correctly for once."
- **Where we are:** Design doc drafted, Oracle (Gemini 2.5 Pro) reviewed and returned PASS with 7 actionable findings. I'm about to apply those fixes. Before I do, I want a 4th outside perspective from a reviewer that hasn't seen this system.

---

## What I want from you

Not validation. Critique. Specifically:

1. **What did the 3 internal advisors + Oracle miss?** They're all biased by having context on this system. You're not. What class of failure are we blind to?
2. **Is the directory state machine the right pattern, or are we in a local maximum?** We rejected SQLite because Syncthing would corrupt WAL files. Is there a third option we're not seeing?
3. **Is the migration plan realistic?** 3 weeks, one agent per day in Week 2, observer mode Week 1, cleanup Week 3. Oracle pushed for a "dark launch" parallel run before Lobster migrates. Is that enough safety margin for a solo operator?
4. **The review → fix closure loop** — Oracle said my "watch git commits for Fixes: <finding_id>" was brittle. Recommended explicit `close-finding` events. Do you agree? What's the right pattern here?
5. **SPOF risk.** Only Mini runs the daemon. MacBook reads via Syncthing. Oracle recommended documenting a manual cold failover procedure instead of building HA. For a solo founder, is this the right tradeoff?

Answer with concrete recommendations. No hedging. If you disagree with Oracle, say so. If you think the whole direction is wrong, say that instead.

---

## The Design Doc (what you're reviewing)

```
# DESIGN — MyndAIX Control-Plane Daemon

## Problem
MyndAIX has 5+ execution surfaces that can independently dispatch agent work
(inbox file drop, PostToolUse hooks, watcher crons, dispatch.sh, auto-router,
trigger-review). No single authority; no single view. Symptoms:
- "Lobster looping in Discord" was actually an auto-review PostToolUse hook
  posting P0/P1 alerts into command-center. Not an LLM bug.
- lobster-monitor.sh ran uncommitted in production for weeks.
- Enforcement hook blocked its own dispatches because systems-check.sh never
  wrote the marker it required.
- dispatch.sh emits task types PROTOCOL.md doesn't define.
- Findings from KilaBz reviews rot — nothing tracks whether a P1 got fixed.

Root cause: no single dispatch authority; no single source of truth for
task state.

## Objective
Replace all dispatch surfaces with a single daemon that owns task lifecycle.
Every agent interaction — hook event, watcher observation, Discord message,
inbox drop — becomes an event reported to the daemon. Only the daemon
mutates task state. Only the daemon dispatches work.

## Non-Goals
- Rewriting OpenClaw integration (keep as external service).
- Replacing Syncthing (it works; the issue was what was synced, not the sync).
- Right-sizing the agent fleet.
- Kafka/RabbitMQ/SQLite/any "real" message queue. File-based inspectability
  is an operating constraint — ls/cat/grep must stay as debugging tools.

## Core Invariants (ranked by blast radius)
1. Single dispatch authority. Daemon is the only process allowed to mutate
   task state directories or dispatch agent work. Hooks, watchers, Discord
   listeners are event sources; they report events and stop.
2. Operator-alert channel separation at protocol. Two Discord webhooks:
   $DISCORD_WEBHOOK_OPS for human↔Lobster. $DISCORD_WEBHOOK_ALERTS for
   daemon-authored automation notices. An auto-generated message posted to
   the ops webhook is a contract violation the daemon logs and drops.
3. File inspectability preserved. Task state lives in per-task markdown
   files that move between directories. JSONL audit log records every state
   transition. No binary storage, no SQLite, no database.

## Target Architecture (5 components, no more)
| Component | Owner | Authority | Failure signal |
|-----------|-------|-----------|----------------|
| Daemon (bash, launchd-managed) | the user | Only process that mutates state/tasks/ and writes to state/audit.jsonl. Only dispatcher. | daemon exits unexpectedly; heartbeat stale >60s; any other process writes to state dirs |
| Event ingesters (hooks, watchers, Discord listener) | the user | Observers only. Write events to state/events/incoming/; never mutate task state. | event file unclaimed by daemon >30s = daemon down |
| Agent workers (Lobster, Mack, Mini, KilaBz, etc.) | the user | Pull work from daemon's outbound spool (state/tasks/active/<agent>/); write results to state/tasks/done/<agent>/. | no heartbeat from agent >5min while active task exists |
| Operator interface (#command-center, CLI `mx status`) | the user | Read-only view of daemon state + manual task submission via state/events/incoming/. | cannot render current task state = daemon down |
| Alert sink (#alerts, state/audit.jsonl) | Daemon | Daemon-authored only. Operator reads, never writes. | message in #alerts with from != "daemon" = protocol violation |

## Directory State Machine
state/
├── events/
│   ├── incoming/         # event sources drop here; daemon claims
│   └── processed/        # daemon moves here after ingestion
├── tasks/
│   ├── pending/          # daemon has claimed event, waiting for worker slot
│   ├── active/<agent>/   # dispatched to agent; agent reads here
│   └── done/<agent>/     # worker moved here on completion
│   └── failed/<agent>/   # worker moved here on failure
├── findings/             # reviewer findings, tracked by state
│   ├── open/             # not yet addressed
│   ├── fixed/            # referenced by a later commit; daemon moves here
│   └── wontfix/          # operator-marked
├── audit.jsonl           # append-only; one event per state transition
└── daemon.pid            # daemon singleton lock (atomic mkdir)

Every transition = atomic filesystem rename. Audit log written AFTER rename.

## Migration (3 weeks)
Week 1 — Observer daemon. Tails existing inbox/outbox, records to audit.jsonl,
dispatches nothing. Success: every task appears in audit.jsonl within 5s.
Week 2 — Single-agent migration per day. smoke → Lobster (Day 3, dual-
authority is the exact bug) → KilaBz → Oracle → Antman → Recon → Harley → Mack.
Week 3 — Delete old paths, update PROTOCOL.md, stress test.
```

---

## Oracle's Review (PASS with 7 findings I'm about to apply)

**P0 (critical):**
- Race condition in finding-fix closure. Daemon reading findings/open/ while
  post-commit hook fires = check-then-act race. Fix: directory read-lock.

**P1 (high):**
1. "Fixes: <finding_id>" in commit messages is brittle. Replace with explicit
   `close-finding` event type written by reviewer after verifying the fix.
2. SPOF on Mini. Document manual cold failover procedure (not full HA).
3. Event ID collision should rename-and-warn, not reject (prevents silent
   event loss).

**P2 (medium):**
4. Lock-directory corruption needs explicit fatal-exit if state/daemon.pid
   exists but isn't a manageable directory.
5. Global 10-min timeout too coarse. Per-task `timeout_minutes` frontmatter
   field with conservative default (30 min).

**P3 (low):**
6. Event IDs should include hostname: YYYYMMDDHHMMSS-<hostname>-<8char>.

**Migration safety recommendation (Oracle-original):**
Before migrating Lobster (the orchestrator — highest-risk step), add a
"dark launch" day. Run daemon dispatching to a parallel Lobster instance
that only logs its outputs, doesn't act. Compare against still-live old
Lobster for 24h. Only cut over if outputs match.

---

## What I'm about to accept as-is from Oracle

All 7 findings. The dark-launch migration day especially — cheap insurance
against orchestrator failure.

## What you should push on

What are we STILL missing?
