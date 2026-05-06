# Boardroom Synthesis: MyndAIX Control-Plane Rebuild
**Date:** 2026-04-21
**Task ID:** boardroom-rebuild-20260421
**Advisors:** Advisor 1 (pragmatic systems engineer), Advisor 2 (distributed systems skeptic), Advisor 3 (security & organizational skeptic)

---

## 1. Convergence Points (all 3 advisors agreed)

1. **Single dispatch authority is the correct root cause.** All three advisors confirmed that 5+ execution surfaces independently dispatching agent work is the root cause of every observed failure (phantom looping, enforcement-blocks-itself, protocol drift). Mack's #1 invariant is correct.

2. **Kill the auto-review PostToolUse Discord hook immediately.** All three listed this as "do tomorrow, takes 15 minutes." It's the root cause of the phantom LLM looping, zero rollback risk. This is the single highest-value action.

3. **Discord channel hard-separation is correct and cheap.** Operator channel (user ↔ Lobster) must never receive automated alerts. Enforced at protocol level (separate webhooks), not convention. All three advisors proposed this with identical reasoning.

4. **Append-only JSONL audit log is the right observability primitive.** All three proposed an append-only event log as the audit trail. None disagreed — the only variation was what else sits alongside it (SQLite, directory state machine, or nothing).

5. **Observer-first migration is sound.** Read-only shadow mode before taking over dispatch authority was validated by all three as the correct migration pattern for stateful systems.

---

## 2. Divergence Points (advisors disagreed)

### SQLite: The Central Split

| | Advisor 1 (Claude) | Advisor 2 (GPT) | Advisor 3 (Gemini) |
|---|---|---|---|
| **State store** | Directory state machine (`incoming/` → `pending/` → `active/` → `done/`) + JSONL audit | SQLite on Mini only, MacBook via Tailscale HTTP. Never sync SQLite via Syncthing. | No new state store. Harden dispatch.sh + JSONL audit. |
| **Rationale** | File inspectability is the system's core operational property. `ls` and `cat` > `sqlite3`. | SQLite is correct but must be single-writer, single-machine. Cross-machine sync via Syncthing = corruption. | Solo founder 13 days from YC deadline cannot build and maintain a SQLite daemon. It adds operational load. |

**Lobster's assessment:** All three reject Mack's SQLite-over-Syncthing as proposed. A1 and A3 reject SQLite entirely. A2 accepts SQLite but radically constrains it (Mini-only, Tailscale access, Syncthing ignore list). The convergence is: **files remain the source of truth for task state; JSONL is the audit log.**

### Daemon vs. No Daemon

| | Advisor 1 | Advisor 2 | Advisor 3 |
|---|---|---|---|
| **Build a new daemon?** | Yes — bash process, directory-based state machine | Yes — launchd-managed, SQLite-backed, with watchdog | **No** — harden dispatch.sh as the single dispatch gate |
| **Rationale** | Need a process to enforce state transitions | Need a process for crash recovery and re-queuing | The problem is discipline + sprawl, not missing software. Adding a daemon adds maintenance load. |

**Lobster's assessment:** A3's "no daemon" position is the strongest given the YC timeline. Steps 1-3 of A3's migration (kill hook, add commit gate, merge trigger-review) can happen tomorrow in 90 minutes with zero new systems. A daemon can follow post-YC if still needed.

### Migration Sequence — Who Goes First?

| | Advisor 1 | Advisor 2 | Advisor 3 |
|---|---|---|---|
| **First agent migrated** | Lobster (Day 5) — it's the orchestrator, dual-authority is the exact bug | Recon — lowest traffic, idempotent | N/A — no daemon, just strip dispatch from watchers |
| **Total timeline** | 11 days | 21 days | 7 days |

**Lobster's assessment:** A1's point about Lobster-first is architecturally correct (dual-authority during migration is the bug you're fixing), but A3's 7-day timeline is the only one compatible with YC.

---

## 3. Missed Considerations (not in Mack's proposal)

1. **YC timeline conflict (Advisor 3).** 4-week migration timeline vs. May 4 YC deadline (13 days) is incompatible. Stalling at week 2 leaves two systems running in parallel — strictly worse than today. This is the killer insight Mack's proposal doesn't address.

2. **Syncthing + SQLite corruption risk (Advisors 1 & 2).** Mack says "SQLite WAL as authoritative state" but never specifies which machine owns the write lock, how the other machine reads it, or what happens if Syncthing syncs the WAL/SHM files. This is a data corruption risk, not a theoretical concern.

3. **Daemon crash recovery (Advisor 2).** Single authority with no watchdog is a different single point of failure. Who restarts the daemon? What about in-flight tasks? Need a launchd watchdog + stuck-task reaper.

4. **Commit gate as enforcement, not convention (Advisor 3).** The 517-line uncommitted watcher is a discipline failure. A 15-line `git status --porcelain` check in dispatch.sh enforces commit-before-dispatch mechanically, without a new system.

5. **Operational load on solo founder (Advisor 3).** The rebuild adds monitoring, watchdog management, migration rollbacks, and SQLite administration. The person who didn't commit the watcher script now has to maintain a daemon. The proposal treats the human bottleneck as constant but increases demands on it.

---

## 4. Recommended Next Step

**Don't build the daemon yet. Do the 7-day minimal fix first.**

Advisor 3's migration is the right move for the next 13 days:

| Day | Action | Time | Risk |
|-----|--------|------|------|
| Tomorrow | Kill auto-review hook, add commit gate to dispatch.sh, merge trigger-review.sh | 90 min | Zero |
| Day 3 | Delete auto-router, move routing into dispatch.sh | 1 hr | Low |
| Day 4 | Strip dispatch capability from all watcher scripts | 1.5 hr | Low |
| Day 5 | Add append-only JSONL state log | 45 min | Zero |
| Day 7 | Update PROTOCOL.md, delete dead code, commit everything | 1 hr | Zero |

**Total: ~6 hours over 7 days. No new systems. No daemon. No SQLite.**

After YC (post-May 4), if the hardened dispatch.sh + audit log isn't sufficient, build the daemon using Advisor 1's directory-based state machine architecture (not SQLite). That design preserves file inspectability and is Syncthing-safe.

**Decision log:**

| Item | Verdict | When |
|------|---------|------|
| Auto-review Discord hook | **REMOVE** | Tomorrow |
| Commit gate in dispatch.sh | **ADD** | Tomorrow |
| trigger-review.sh | **MERGE** into dispatch.sh | Tomorrow |
| auto-router | **DELETE** | Day 3 |
| Watcher dispatch capability | **STRIP** | Day 4 |
| Append-only JSONL audit | **ADD** | Day 5 |
| PROTOCOL.md | **UPDATE** to match reality | Day 7 |
| SQLite daemon | **DEFER** | Post-YC |
| OpenClaw integration rewrite | **DEFER** | Post-YC |
| Syncthing replacement | **KEEP** (do not replace) | N/A |
