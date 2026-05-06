# Perplexity Computer — MyndAIX v2 Architecture Map

**Received:** 2026-04-21 | **Source:** Perplexity Computer (Comet)
**Status:** Canonical reference — CORRECTIONS APPLIED per user clarifications (see below)

---

## the user's Corrections (applied after PC delivered)

PC's architecture assumed Claude Code (Mack) is the orchestrator and MacBook runs a peer `mxd`. the user corrected:

1. **MacBook is not always on.** the user doesn't keep his laptop running 24/7.
2. **Mini is the always-on hub.** All agents + the daemon live there.
3. **Mack is NOT the orchestrator.** Mack is the interactive hands-on builder. the user opens Claude Code when he wants to pair-program with Mack.
4. **Lobster stays.** Discord-based orchestrator, always on, runs on Mini. Primary interface for mobile / job-site / async use.
5. **Mini agent is the autonomous clone of Mack.** Same Claude Opus, different operating mode. Receives dispatches from Lobster.
6. **Skills/rules sync is the propagation mechanism** that makes "Mini as clone of Mack" real.

**What this changes in PC's doc:**
- MacBook's `mxd` — removed. Only Mini runs the daemon.
- Section 2 data flow: autonomous path runs entirely on Mini. No cross-machine state flow.
- Section 7: Claude Code is NOT an orchestrator. Lobster is the orchestrator. Claude Code is an interactive peer for Mack work.
- `machine_target` field — removed. Single-machine daemon means no cross-machine race.
- Section 9 migration Phase 3: "Lobster retired" → "Lobster reduced to thin Discord-to-mx wrapper (~100 lines), OpenClaw simplified."

The rest of PC's design is correct and adopted below.

---

## Architectural Thesis

Two jobs with different availability requirements:
- **Job A — Interactive orchestration:** user at terminal with Mack. Claude Code's strength.
- **Job B — Background execution:** Scheduled, overnight, health watchdog. Needs to run while the user sleeps.

v2 splits them cleanly:
- **Mack** (Claude Code on MacBook) — pair-programming peer for Job A. Not an orchestrator.
- **Lobster** (Discord bot on Mini) — conversational dispatcher, primary orchestrator for the user's async/mobile interaction.
- **mxd** (Node.js daemon on Mini) — owns Job B. Single authority for state, audit, scheduled work.

If `mxd` grows past ~200 lines, something has gone wrong. Hard scope cap.

---

## Component Inventory (corrected)

| Component | Role | Lifecycle | Language | Machine |
|---|---|---|---|---|
| **Mack** (Claude Code) | Interactive hands-on builder; pair programs with the user | On-demand | Claude Code CLI | MacBook |
| **Lobster** | Discord orchestrator; thin wrapper around `mx dispatch` | Always-on | Node.js (~100 LOC) | Mini |
| **mxd** | Background daemon: queue runner, audit writer, scheduled tasks, health monitor | Always-on (launchd) | Node.js (~200 LOC cap) | Mini |
| **mx** (CLI) | Operator command surface | On-demand | Node.js | Both machines |
| **Mini** (agent) | Autonomous clone of Mack | On-demand | Claude CLI | Mini |
| **KilaBz** | Code reviewer (read-only) | On-demand | Codex CLI | Mini |
| **Oracle** | Architecture/security reviewer | On-demand | Gemini REST | Mini |
| **Antman** | Builder + second opinion | On-demand | Codex CLI | Mini |
| **Recon** | Research (sole Perplexity caller) | On-demand | Shell + Perplexity API | Mini |
| **Harley** | Creative strategy | On-demand | Claude CLI | Mini |
| **Smoke** | Pipeline canary | On-demand | Claude CLI | Mini |
| **Syncthing** | Cross-machine sync (state READ-ONLY to MacBook) | Always-on | System service | Both |

**State / audit live on Mini only.** Syncthing replicates to MacBook in read-only view for when the user wants to inspect from his laptop.

---

## Data Flow (corrected)

### Interactive path (user with Mack at MacBook)
```
user at terminal → Mack reasons → bash: mx dispatch (if external agent needed)
  → task written to Mini's state/pending/ via SSH or Syncthing inbox drop
  → Mini's mxd picks up → agent executes → result back via Syncthing
  → Mack reads result → continues with the user
```

### Async path (user on phone → Lobster)
```
User in Discord → Lobster receives message → Lobster calls mx dispatch
  → mxd enqueues → agent executes → result → Lobster posts back to Discord
```

### Autonomous path (user asleep)
```
launchd fires scheduled task OR queue has pending work
  → mxd runs queue per backpressure config
  → agent executes → result in done/
  → alert posted to #alerts if failed
```

All three converge on the same backend: mxd on Mini, single writer, directory state machine, JSONL audit log.

---

## Directory state machine

```
state/
├── pending/     ← events arrive; mxd claims via atomic rename
├── running/     ← actively executing
├── done/        ← completed successfully
├── failed/      ← timed out, cancelled, or errored
└── processed/   ← cold archive (mx archive moves done/ older than 7d here)
```

Every state file is a complete JSON record. Transitions are `rename()` calls — atomic on POSIX. No partial states.

---

## CLI surface (`mx`)

```bash
mx dispatch <agent> <task-file>       # queue task
mx dispatch <agent> --inline "..."    # one-liner
mx status [--agent X] [--watch]       # health + queue view
mx inspect <uuid>                     # full task JSON + audit trail
mx audit --since 1h [--event failed]  # tail audit.jsonl
mx queue list | drain | flush
mx cancel <uuid> | retry <uuid>
mx health                             # mxd alive? Syncthing synced? heartbeats?
mx archive                            # done/ → processed/ for old tasks
mx fidelity status                    # Mini vs Mack behavior check results
mx context                            # dump state summary for Claude Code session startup
mx logs <agent> [--lines 50]
```

---

## File layout (corrected)

```
~/.myndaix/                         # SYNCED (Syncthing)
├── rules/                          # Universal rules for all agents
├── agent-knowledge/                # Per-agent personas
├── skills/                         # Executable capabilities
├── prompt-assembly/assemble.sh     # Canonical prompt builder
├── fidelity/                       # Mack↔Mini fidelity tests
├── config.json                     # mxd + mx config
├── scheduled/                      # cron-style YAML for overnight tasks
└── .secrets                        # NOT synced; local only per machine

~/.myndaix/state/         # MINI ONLY (authoritative)
├── pending/  running/  done/  failed/  processed/

~/.myndaix/state/                   # MacBook — SYNCED READ-ONLY projection

~/.myndaix/audit.jsonl    # MINI ONLY (authoritative append)
~/.myndaix/audit.jsonl              # MacBook — SYNCED READ-ONLY projection

~/.myndaix/logs/          # NOT synced (per-machine)
~/.myndaix/logs/                    # NOT synced
```

**Single-writer invariant held:** only mxd on Mini writes state/ and audit.jsonl. MacBook observes via Syncthing read-only.

---

## Core Schemas (canonical)

### Task record — `state/<stage>/<uuid>.json`

```json
{
  "schema_version": "2.0",
  "id": "task_01J8X4...",
  "created_at": "2026-04-21T22:00:00Z",
  "created_by": "mack | lobster | cron | mx-cli",
  "agent": "mini | kilabz | oracle | antman | recon | harley | smoke",
  "priority": "normal | high",
  "timeout_minutes": 30,
  "depends_on": [],
  "context": {
    "project": "fieldvision",
    "branch": "feat/...",
    "working_dir": "~/dev/fieldvision"
  },
  "task": {
    "type": "build | review | research | strategy",
    "description": "...",
    "files": [],
    "acceptance_criteria": "..."
  },
  "dispatch_source": "discord_lobster | claude_code | mx_cli | scheduled"
}
```

### Audit entry — one JSON per line in `audit.jsonl`

```json
{"ts":"...","event":"dispatched|started|completed|failed|timeout|cancelled|retried|rate_limited","task_id":"...","agent":"...","by":"...","source":"...","exit_code":0,"duration_ms":0}
```

### Config — `~/.myndaix/config.json`

```json
{
  "agents": {
    "mini":   { "max_concurrent": 1, "max_queued": 5, "default_timeout_minutes": 45 },
    "kilabz": { "max_concurrent": 2, "max_queued": 10, "default_timeout_minutes": 15 },
    "oracle": { "max_concurrent": 1, "max_queued": 3, "default_timeout_minutes": 20 },
    "recon":  { "max_concurrent": 2, "max_queued": 10, "default_timeout_minutes": 10 },
    "harley": { "max_concurrent": 1, "max_queued": 5, "default_timeout_minutes": 30 },
    "antman": { "max_concurrent": 1, "max_queued": 5, "default_timeout_minutes": 45 },
    "smoke":  { "max_concurrent": 1, "max_queued": 2, "default_timeout_minutes": 5 }
  },
  "discord": {
    "enabled": true,
    "ops_channel_id": "...",
    "alerts_channel_id": "...",
    "per_agent_channels": { "mack": "...", "kilabz": "...", "oracle": "..." },
    "alert_on": ["failed", "timeout", "rate_limited"]
  },
  "perplexity": {
    "cache_ttl_minutes": 60,
    "max_retries": 3,
    "retry_backoff_seconds": [10, 30, 90]
  }
}
```

---

## Top 3 Risks (PC-identified, still valid)

1. **Claude Code session discontinuity.** No cross-session memory for Mack. Mitigation: `mx context` dumps summary Claude Code ingests at startup.
2. **mxd scope creep.** v1 daemon grew to 517 lines. Write acceptance tests day one; hard 200-LOC cap enforced.
3. **Syncthing latency on state reads.** MacBook's read-only projection lags Mini by ~2s. Not blocking (MacBook doesn't dispatch autonomously) but surfaces as "last task status slightly stale" on laptop.

---

## Three Open Questions (must answer before Phase 0)

1. **Context re-hydration for Claude Code.** When the user opens terminal, how does Mack get last session's state? Proposed: startup hook reads `mx context --json` + last 50 audit entries.
2. **Overnight trigger mechanism.** `~/.myndaix/scheduled/` YAML dir read at mxd startup → launchd fires `mx dispatch` on schedule. Or defer scheduled work entirely to v2.1 and start with manual-queue-only.
3. **Lobster's Discord interface shape.** What exact Discord commands does Lobster respond to? `@Lobster dispatch kilabz review this file`? Natural language parsing? Slash commands? Must lock before Phase 3.

---

## Confidence

**High.** Architecture is internally consistent, aligns with the user's operational reality (mobile-first, laptop-sometimes), respects tonight's 12 locked decisions, and has rollback at every migration phase.
