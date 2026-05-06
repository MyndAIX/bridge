# Boardroom: MyndAIX Control-Plane Rebuild — Raw Output
**Date:** 2026-04-21
**Task ID:** boardroom-rebuild-20260421
**Advisors:** 3 (Claude perspective, GPT perspective, Gemini perspective)
**Rounds:** 3 per advisor (Diagnose → Propose → Migrate)

---

# ADVISOR 1 (Claude Perspective) — Pragmatic Systems Engineer

## ROUND 1 — DIAGNOSE

### 3 Things Mack Gets Right

**1. Single authority for task lifecycle is the correct #1 invariant.** Five dispatch surfaces (inbox drop, PostToolUse hook, watcher cron, dispatch.sh, auto-router, trigger-review) is the root cause of every observed failure. The enforcement hook blocking its own dispatches is a textbook symptom: two authorities disagreed on what constitutes valid work. Collapsing to one daemon that owns dispatch is correct.

**2. The observer-daemon-first migration is sound.** Week 1 as read-only shadow mode is the right instinct. You get to validate that the daemon's state model captures reality before you trust it to make decisions. The 5-second detection window is a concrete, testable metric. This is how you migrate stateful systems without a flag day.

**3. Identifying Discord channel bleed as a protocol-level problem, not a configuration problem.** The "LLM looping" misdiagnosis happened because alert traffic and operator traffic shared a channel. Hard separation at the protocol level (not just "please post to the right channel") is correct. Contract violation logging means you detect regression automatically.

### 2 Things Wrong or Missing

**1. SQLite WAL as authoritative state is over-indexed on consistency and under-indexed on inspectability.** This is my primary disagreement. The file-based system has a critical operational property: the user can `ls inbox/mini/`, `cat` a task file, and understand system state with zero tooling. SQLite kills that. You can't `tail -f` a WAL. You can't Syncthing a SQLite database reliably across two machines (write conflicts will corrupt it). The proposal says "markdown stays as content" but if SQLite is truth, the markdown files become stale lies the moment anything fails — which is exactly the divergence alarm Mack defines but doesn't want to deal with at 2am.

The actual problem isn't "files are unreliable as state." It's "files are state but nobody enforces transitions." You don't need a database. You need a state machine that moves files through well-defined directories atomically, with a manifest file (append-only JSONL) as the audit log. Same guarantees, fully inspectable, Syncthing-safe.

**2. The migration sequence buries the highest-risk move.** Lobster last sounds safe but is backwards. Lobster is the orchestrator — it dispatches to everyone else. If you migrate all workers to pull from the daemon but Lobster is still dispatching via the old path, you have two authorities running simultaneously for three weeks. That's the exact problem you're solving. Lobster should be week 2, right after the smoke agent proves the pattern. Workers that only consume (KilaBz, Oracle) are low-risk and can migrate in any order after that.

---

## ROUND 2 — PROPOSE

### Top 3 Invariants (by blast radius)

1. **One process dispatches work.** The daemon is the only writer to agent work queues. Everything else is an event source. Violation signal: any non-daemon process creating files in an agent's `pending/` directory.
2. **State transitions are directory moves, audit is append-only.** A task's lifecycle is: `incoming/` → `pending/{agent}/` → `active/{agent}/` → `done/` or `failed/`. Each move is atomic `mv`. Every transition appends to `state/audit.jsonl`. Violation signal: audit log and directory contents disagree.
3. **Operator and alert channels never cross.** Daemon never writes to operator channel. Hooks never write to operator channel. Violation signal: any bot-authored message in command-center.

### 5 Components

| Component | What | Owner | Authority Over | Failure Signal |
|-----------|------|-------|---------------|----------------|
| **Task Daemon** | State machine, reads event queue, dispatches to agent pending dirs, enforces caps/dedup | Single bash process on Mini, LaunchAgent | Task lifecycle, scheduling, rate limits | Heartbeat missing >30s in `state/daemon.heartbeat` |
| **Event Ingesters** | PostToolUse hook, Discord listener, manual `submit.sh` CLI — all write to `incoming/` only | Individual processes, stateless | Nothing — they propose, daemon decides | Ingester writes directly to `pending/` (alarm) |
| **Agent Workers** | Watcher scripts — poll `pending/{agent}/`, move to `active/`, execute, move to `done/` or `failed/` | Per-agent LaunchAgent | Own execution only | Task in `active/` longer than timeout threshold |
| **Audit Log** | `state/audit.jsonl` — append-only, every state transition logged with timestamp, task_id, from_state, to_state | Daemon + workers append | Historical truth | Gap in sequence numbers |
| **Operator Interface** | Discord ops channel + `status.sh` CLI that reads directory state and audit log | the user | Manual dispatch (writes to `incoming/`) | N/A — read-only except manual submit |

### Keep / Merge / Delete

| Surface | Verdict | Reason |
|---------|---------|--------|
| Inbox file drop | **KEEP** — becomes `incoming/` | Core ingestion, just rename |
| Watcher cron per agent | **KEEP** — becomes agent worker polling `pending/{agent}/` | Already correct pattern, just scope it |
| `dispatch.sh` | **MERGE** into `submit.sh` | One CLI entry point that writes to `incoming/` |
| `trigger-review.sh` | **MERGE** into `submit.sh --type review` | Same ingestion path |
| PostToolUse hook | **KEEP** — writes to `incoming/` only, strip Discord posting | Valuable event source, toxic dispatch surface |
| Auto-router | **DELETE** | Daemon subsumes routing logic |
| Auto-review hook (Discord) | **DELETE day one** | Root cause of phantom looping |
| PID-file locks | **DELETE** — replace with atomic `mkdir` | Already specified in watcher rules, just enforce |
| `processed/` archive | **KEEP** — `done/` is the new name | Inspectability preserved |

---

## ROUND 3 — MIGRATE

### Step 1 (Tomorrow): Kill the auto-review Discord hook, deploy audit log
- **Action:** Remove PostToolUse hook's Discord posting. Deploy `state/audit.jsonl` and a `log_transition()` shell function that all current scripts can source. Add it to the existing watcher as a non-blocking append after each task completes.
- **Rollback:** Re-enable hook (it's a config line).
- **Success metric:** 24 hours of audit entries with zero gaps, covering all task completions across both machines.

### Step 2 (Tomorrow +1): Deploy directory structure and daemon in shadow mode
- **Action:** Create `incoming/`, `pending/{agent}/`, `active/{agent}/`, `done/`, `failed/` alongside existing `inbox/`. Daemon process watches `incoming/`, logs what it *would* route, but does not move files. Existing system runs unchanged.
- **Rollback:** Stop daemon, remove directories.
- **Success metric:** Daemon shadow log matches actual task routing for 48 hours.

### Step 3 (Day 3): Merge dispatch.sh + trigger-review.sh into submit.sh writing to incoming/
- **Action:** New `submit.sh` writes to `incoming/` instead of directly to agent inboxes. Daemon (now active for this path only) routes from `incoming/` to `pending/{agent}/`. Old `dispatch.sh` becomes a wrapper that calls `submit.sh` (backward compat).
- **Rollback:** Point `dispatch.sh` wrapper back to direct inbox writes.
- **Success metric:** All manually dispatched tasks flow through daemon.

### Step 4 (Day 5): Migrate Lobster to pull from daemon
- **Action:** Lobster's event processing switches from inbox polling to `pending/lobster/`. Lobster's dispatches go to `incoming/` not directly to agent inboxes.
- **Rollback:** Revert Lobster's watcher to inbox polling.
- **Success metric:** Lobster processes 10+ tasks with zero dropped or duplicated work.

### Step 5 (Days 6-8): Migrate workers in order: KilaBz, Oracle, Antman, Recon, Harley
- **Action:** One agent per day. Switch watcher to poll `pending/{agent}/`, move to `active/` on pickup, `done/` on completion.
- **Rollback:** Per-agent revert to legacy inbox.
- **Success metric:** Each agent completes 3+ tasks through new path without error.

### Step 6 (Day 9): Migrate Mack and Mini
- **Action:** Builder agents switch to new path. Dual-write period ends.
- **Rollback:** Re-enable dual-write.
- **Success metric:** Full 24-hour cycle with all agents on new path, audit log complete.

### Step 7 (Day 11): Delete legacy paths
- **Action:** Remove `inbox/` directories, `dispatch.sh`, `trigger-review.sh`, auto-router, PID locks. `submit.sh` is the only ingestion CLI. Daemon is the only router.
- **Rollback:** Git revert — all old scripts are committed (enforce this before deletion).
- **Success metric:** `find ~/.myndaix/bridge/inbox -name "*.md"` returns nothing for 48 hours.

---

# ADVISOR 2 (GPT Perspective) — Distributed Systems Skeptic

## ROUND 1 — DIAGNOSE

### What Mack Gets Right

**1. Single authority is the correct root cause identification.** Five dispatch surfaces means no component can answer "is this task already running?" The autoimmune guard failure — systems-check.sh never writing the marker its own enforcement hook required — is a textbook symptom of distributed authority with no coordination.

**2. The Discord channel conflation diagnosis is precise.** Auto-review hook posting alerts into the operator channel created phantom "LLM looping." Hard-separating these at protocol level is correct and low-risk.

**3. The migration sequence is conservative in the right direction.** Observer-first before any dispatch authority transfer is exactly right.

### What Mack Gets Wrong or Misses

**1. SQLite as cross-machine authority is a landmine Mack doesn't defuse.** Mini and MacBook sync via Syncthing. SQLite-WAL mode requires that only one process on one machine hold write access. Syncthing syncing a WAL file is not safe — partial sync of the WAL or SHM file will corrupt the database. Mack's proposal never addresses which machine owns the database, how the other machine reads it, or what happens during a Syncthing conflict. You cannot have two SQLite writers on two machines connected by Syncthing. Period.

**2. The daemon is a single point of failure with no specified recovery.** If the daemon crashes mid-task-transition, what happens? The proposal says "alarm" on divergence but never specifies: Who restarts the daemon? What's the recovery protocol for in-flight tasks? Is there a WAL replay mechanism? A single-authority-with-no-watchdog is just a different failure mode.

---

## ROUND 2 — PROPOSE

### Top 3 Invariants by Blast Radius

1. **Single machine owns task state; other machine is a read-only replica.** Mini is the daemon host. MacBook agents query Mini's daemon via Tailscale, never write local state.
2. **Every state transition is journaled before side effects.** Daemon writes intent to append-only log before dispatching. Crash recovery replays the journal.
3. **Hard separation: event sources cannot mutate task state.** Event sources write to `ingest/`, daemon polls it, nothing else touches task lifecycle.

### Target Architecture — 5 Components

| # | Component | Owner | Authority | Failure Signal |
|---|-----------|-------|-----------|----------------|
| 1 | **Task Daemon** (Mini only) | Mini's launchd | Sole authority for task lifecycle. Owns SQLite DB + append-only journal. | Heartbeat file not updated in 30s → launchd restarts. Journal entry with no completion after TTL → stuck-task alert. |
| 2 | **Ingest Directory** (`bridge/ingest/`) | Syncthing + local writers | Receives event markdown from all sources. NOT authoritative — daemon consumes and deletes. | Files older than 60s in ingest/ → daemon is stalled or dead. |
| 3 | **Agent Workers** (all machines) | Each agent's watcher | Pull work from daemon via local socket (Mini) or Tailscale HTTP (MacBook). Report completion back to daemon. | Agent heartbeat missing → daemon marks tasks as timed-out, re-queues. |
| 4 | **Content Store** (`bridge/content/`) | Syncthing | Markdown task bodies, results, knowledge. Synced freely. NOT state — just content. | Syncthing conflict files → alert, human resolution. |
| 5 | **Operator Interface** (Discord ops + CLI) | the user | Read-only view of daemon state. Manual dispatch writes to ingest/. | Operator command gets no daemon response in 5s → daemon health check. |

### Keep / Merge / Delete

| Surface | Verdict | Rationale |
|---------|---------|-----------|
| Inbox file drop | **Merge** → writes to ingest/ | Same mechanism, single directory |
| PostToolUse hook | **Delete** alert path, **Keep** as event source to ingest/ | Root cause of phantom looping |
| Watcher cron | **Merge** → becomes agent worker pulling from daemon | No longer self-dispatching |
| dispatch.sh | **Delete** | Daemon is sole dispatcher |
| auto-router | **Delete** | Daemon owns routing |
| trigger-review.sh | **Delete** | Replaced by daemon review-dispatch |
| PID-file locks | **Delete** | Daemon owns concurrency |
| Syncthing | **Keep** for content only | Never syncs SQLite or journal |
| Markdown wire format | **Keep** | Inspectability constraint |

---

## ROUND 3 — MIGRATE

### Step 1 — Instrument existing system (Day 1-2)
Add 5-line append to `task-journal.jsonl` in every dispatch surface. One line per event: timestamp, source, task_id, action.
**Rollback:** Remove append lines. **Success:** Journal captures 100% of tasks over 48 hours.

### Step 2 — Deploy passive daemon on Mini (Day 3-5)
Daemon reads journal + polls inbox dirs. Writes to SQLite. Dispatches nothing. Managed by launchd.
**Rollback:** `launchctl unload`. **Success:** Every task in journal appears in SQLite within 5 seconds over 72 hours.

### Step 3 — Split ingest directory (Day 6-7)
Create `bridge/ingest/`. Modify dispatch surfaces to dual-write (existing + ingest/). Daemon consumes from ingest/.
**Rollback:** Stop writing to ingest/. **Success:** Daemon sees tasks with same completeness as journal.

### Step 4 — Migrate first agent: Recon (Day 8-10)
Lowest-traffic, research tasks are idempotent. Recon pulls from daemon instead of inbox.
**Rollback:** Re-enable Recon's inbox watcher. **Success:** 5 consecutive tasks via daemon.

### Step 5 — Migrate remaining agents (Day 11-17)
KilaBz → Oracle → Harley → Antman → Mini → Mack → Lobster. One per day. MacBook agents use Tailscale HTTP.
**Rollback:** Per-agent re-enable old path. **Success:** Zero dropped tasks per agent over 24 hours.

### Step 6 — Delete old dispatch paths (Day 18-19)
Remove dispatch.sh, trigger-review.sh, auto-router, PID-file locks, PostToolUse alert hook. Commit all deletions.
**Rollback:** Git revert. **Success:** grep for old dispatch calls returns zero hits.

### Step 7 — Harden (Day 20-21)
Add daemon watchdog (separate launchd job checks heartbeat). Stuck-task reaper re-queues after 15 min.
**Rollback:** Disable independently. **Success:** Simulated daemon kill recovers within 60 seconds.

**Critical: Add SQLite path to Syncthing ignore list on Day 1.**

---

# ADVISOR 3 (Gemini Perspective) — Security & Organizational Skeptic

## ROUND 1 — DIAGNOSE

### What Mack Gets Right

**1. The dispatch surface sprawl is the actual root cause.** Five-plus entry points that can independently kick off agent work means no single place to answer "what is running right now and why." Mack correctly identifies that hooks/watchers/Discord must become event sources, not dispatchers.

**2. The enforcement-blocks-itself loop is correctly diagnosed as a marker/gate dependency problem.** systems-check.sh never writing the marker that the enforcement hook required is not a bug in either component — it's what happens when two independently deployed scripts share implicit state contracts with no registry.

**3. Uncommitted drift as a systemic failure, not a one-off.** Mack correctly frames this as architectural rather than "just remember to commit." The system's structure makes it easy to deploy without committing because there's no gate that requires it.

### What Mack Gets Wrong or Misses

**1. This is at least 50% a discipline problem, and a daemon doesn't fix discipline.** The uncommitted watcher script ran for weeks not because there was no central authority — it ran because a solo founder under pressure deployed directly and moved on. SQLite WAL doesn't fix that. A new daemon adds operational load to the person who is already overloaded. The rebuild adds more operational discipline requirements, not less. This is the central contradiction Mack doesn't address.

**2. The 4-week migration timeline is fantasy given the YC deadline on May 4.** That's 13 days away. Week 1 alone requires building a SQLite-backed state machine, event ingestion from 5+ sources, and a detection/alarm system. The migration will stall at week 1 or 2, leaving two systems running in parallel indefinitely — which is strictly worse than the current state.

---

## ROUND 2 — PROPOSE

### Top 3 Invariants by Blast Radius

1. **One file creates work, one file marks completion.** No process dispatches except by writing a task file to a single watched directory per agent.
2. **No deploy without commit.** Pre-dispatch hook in dispatch.sh runs `git status --porcelain`. Uncommitted changes → dispatch fails.
3. **Alert channel is write-only from automation, operator channel is write-only from humans.** Enforced by separate webhook URLs.

### Target Architecture — 5 Components

| Component | Owner | Authority Over | Failure Signal |
|-----------|-------|---------------|----------------|
| **dispatch.sh** (consolidated) | the user maintains, all agents call | Task creation, schema validation, commit gate | Task file written without valid YAML |
| **Watcher daemon** (existing, trimmed) | Per-agent LaunchAgent | Task execution for its agent only | Task in inbox >5min without pickup |
| **State log** (append-only JSONL) | dispatch.sh + watchers | Audit trail | Log stops growing |
| **Commit gate** (in dispatch.sh) | dispatch.sh | Deploy discipline | Gate bypassed |
| **Alert webhook** | Watcher scripts | Operator notification | Posts to wrong channel |

### Keep / Merge / Delete

| Surface | Verdict | Rationale |
|---------|---------|-----------|
| dispatch.sh | **KEEP + HARDEN** | Make it the only dispatch path |
| Watcher scripts | **KEEP + TRIM** | Remove dispatch capability |
| PostToolUse auto-review | **DELETE** | Root cause of false alarm |
| trigger-review.sh | **MERGE** into dispatch.sh | Just dispatch with review defaults |
| auto-router | **DELETE** | Routing belongs in dispatch.sh |
| inbox/outbox/processed | **KEEP** | File-based inspectability |
| PID-file locks | **DELETE** | Replace with atomic mkdir |
| PROTOCOL.md | **KEEP + UPDATE** | Must match reality |

---

## ROUND 3 — MIGRATE

### Step 1 — Tomorrow: Kill the auto-review PostToolUse hook
Delete or comment out the hook. Replace with append to alerts.log.
**Rollback:** Uncomment. **Success:** Zero automated messages in operator Discord for 24 hours. **Time:** 15 minutes.

### Step 2 — Tomorrow: Add commit gate to dispatch.sh
15-line function: check `git status --porcelain`, exit 1 if dirty. Log blocked dispatches.
**Rollback:** Remove function call. **Success:** Dirty-repo dispatch fails, clean-repo dispatch succeeds. **Time:** 30 minutes.

### Step 3 — Tomorrow: Merge trigger-review.sh into dispatch.sh
trigger-review.sh becomes `dispatch.sh --type review`. Delete trigger-review.sh.
**Rollback:** Restore from git. **Success:** Identical task files. **Time:** 45 minutes.

### Step 4 — Day 3: Delete auto-router
Move routing logic into dispatch.sh. Remove auto-router script.
**Rollback:** Restore from git. **Success:** 3 test dispatches of different types work. **Time:** 1 hour.

### Step 5 — Day 4: Strip dispatch capability from watchers
Remove any line in watcher scripts that writes to another agent's inbox or calls dispatch.sh.
**Rollback:** Git restore. **Success:** grep shows only own-inbox reads and sender-inbox writes. **Time:** 1.5 hours.

### Step 6 — Day 5: Add append-only state log
Two log-append calls: dispatch.sh (created), watchers (completed/failed). Format: `timestamp|task_id|event|agent|status`.
**Rollback:** Remove append lines. **Success:** Every dispatched task has both created and completed entries after 24 hours. **Time:** 45 minutes.

### Step 7 — Day 7: Update PROTOCOL.md and delete dead code
Enumerate actual task types. Update PROTOCOL.md. Delete PID-file lock code. Commit everything.
**Rollback:** Git restore. **Success:** PROTOCOL.md matches actual task types. **Time:** 1 hour.

**The hard truth:** This system's problems are 50% architectural sprawl and 50% solo-founder-under-pressure skipping steps. Steps 1-3 happen tomorrow in under 90 minutes. No new systems. No daemon. Just delete the bad paths and harden the good one. A SQLite daemon is the right architecture for a 5-person team. For a solo founder 13 days from demo day, it's a trap.
