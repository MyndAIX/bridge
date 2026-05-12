---
title: MyndAIX System Manifest
version: 1.1
created: 2026-05-04
updated: 2026-05-11
authority: canonical reference refreshed per Recon weekly audit
machine_audited: <your-mini-host> (Mac mini M4, macOS 26.2)
---

# MyndAIX System Manifest

> **Note for OSS readers:** This manifest documents one specific two-machine setup as it existed on 2026-05-04. Replace `<MINI_*>`, `<MACBOOK_*>`, and `<your-*-host>` placeholders with your own values. See `SETUP.md` for installation. Concrete numbers (memory, OS build, file counts, branch names) are reported as-of that date — your install will produce different ones, and that's fine.

This document describes the system as it exists on **2026-05-04**, immediately after the seven-agent cleanup week. It is meant to be read by agents, future maintainers, or any new collaborator who needs ground truth without hunting through code.

Format: facts, not aspirations. If something is planned but not built, it's in section 7.

---

## 1. Infrastructure

### Hardware

| Property | Mac Mini (this machine — Mini) | MacBook Pro (Mack) |
|---|---|---|
| Hostname | `<your-mini-host>` | (off-machine; SSH'd as `stevenfernandez@<MACBOOK_TAILSCALE_IP>`) |
| Model | Mac mini M4 (Mac16,10) | (not audited) |
| Chip | Apple M4, 10 cores (4P + 6E) | (not audited) |
| Memory | 24 GB | (not audited) |
| OS | macOS 26.2 (build 25C56) | (not audited) |
| Disk | 228Gi total, 60Gi free, 16% used | (not audited) |
| Tailscale IP | `<MINI_TAILSCALE_IP>` (IPv4); `fd7a:115c:a1e0::5139:8f4c` (IPv6) | `<MACBOOK_TAILSCALE_IP>` (`mack-watcher.sh::MACBOOK_IP`) |
| Tailscale CLI | not in PATH; binary at `/Applications/Tailscale.app/Contents/MacOS/Tailscale` | n/a |
| Role | Always-on host: bridge, watchers, daemon, Lobster relay | Hands-on builder; runs Mack interactively |

### Syncthing

- Process: `/opt/homebrew/opt/syncthing/bin/syncthing` (running, two child processes)
- Config: `~/Library/Application Support/Syncthing/config.xml`
- Synced folder: **only one** — `myndaix-bridge` at `~/.myndaix/bridge`
- This is the bridge directory shared between Mini and MacBook so both machines see the same `inbox/`, `processed/`, `state/`, `watchers/`, etc.

### PM2 processes (Mini)

| Name | Status | Restarts | Notes |
|---|---|---|---|
| `lobster-notifier` | online | 0 | `~/.myndaix/lobster-bot/notifier.js` — watches `inbox/lobster/` and posts results to Discord |
| `myndaix-daemon` | online | reset 2026-05-04 | `~/.myndaix/bridge/myndaix-daemon.js` v2.0 — sole process manager for the daemon as of 2026-05-04. The competing `ai.myndaix.daemon` LaunchAgent has been disabled (moved to `~/Library/LaunchAgents/disabled/`); restart count reset from 48,573 → 0 (counter rises with each subsequent `pm2 restart` — check `pm2 list` for current value). |

### LaunchAgents (Mini)

**19 `ai.myndaix.*.plist` files in `~/Library/LaunchAgents/`, plus 6 `com.myndaix.*.plist` files. 25 total loaded in `launchctl list` (the `.plist.disabled` rename is excluded; `ai.myndaix.daemon.plist` was moved to `disabled/` subdir on 2026-05-04). Run `launchctl list | grep myndaix` for the live set.**

PID-bound (have a PID in `launchctl list`):

| Label | Namespace | Purpose |
|---|---|---|
| `ai.myndaix.auto-router` | ai.myndaix | Routes inbound bridge traffic by type |
| `ai.myndaix.inbox-dispatcher` | ai.myndaix | Drives task dispatch |
| `ai.myndaix.inbox-watcher` | ai.myndaix | Inbox-level event handler |
| `com.myndaix.auth-watchdog` | com.myndaix | Authentication monitoring (PID 42892) |
| `com.myndaix.notion-sync` | com.myndaix | Notion ↔ bridge sync (loaded via launchctl; plist not in the standard `~/Library/LaunchAgents/` location — investigate if needed) |
| `com.myndaix.claw-cursor` | com.myndaix | OpenClaw / Claude Code session helper |

Event-driven (no PID, fire on file event or schedule):

- **`ai.myndaix.*`** — `mini-watcher`, `antman-watcher`, `kilabz-watcher`, `oracle-watcher`, `recon-watcher`, `harley-watcher`, `smoke-watcher`, `lobster-monitor`, `bridge-watchdog`, `discord-relay`, `heartbeat-check`, `homeostasis`, `memory-decay`, `worktree-cleanup`, `weekly-audit`, `secrets-audit`
- **`com.myndaix.*`** — `log-rotation`, `notion-poller`, `codex-token-refresh`, `tts-bridge` (Disabled=true)

Disabled persistently:

- `ai.myndaix.mack-watcher.plist.disabled` — renamed from `.plist` so launchd cannot load it. Mack runs on MacBook only.
- `ai.myndaix.daemon.plist` — moved to `~/Library/LaunchAgents/disabled/` on 2026-05-04 to end the PM2/LaunchAgent restart race (48,573 PM2 restarts). PM2 is now the sole process manager for `myndaix-daemon.js`.

### Key paths (all rooted at `~/.myndaix/`)

| Path | Purpose |
|---|---|
| `bridge/` (521 MB total ~/.myndaix; 98 MB this dir) | Multi-agent message bus (Syncthing-shared) |
| `bridge/watchers/` | Watcher + runner scripts (113 entries; many `.bak`/`.pre-*` snapshots) |
| `bridge/watchers/lib/` | Shared libraries: `common.sh`, `guardrails.sh`, `chaining.sh`, `context.sh`, `knowledge.sh`, `parallel.sh`, `preflight.sh`, `self-healing.sh` |
| `bridge/inbox/<agent>/` | Per-agent inbox (lobster, mini, mack, antman, kilabz, oracle, recon, harley, smoke, dispatch) |
| `bridge/processed/` | Archived tasks (660 entries) |
| `bridge/state/` | Heartbeats, daily-runs, dedupe markers, paused flags, checkpoints |
| `bridge/scripts/` | Dispatch + maintenance scripts (51 entries) |
| `bridge/hooks/` | Claude Code hook scripts: `branch-guard.sh`, `destructive-blocker.sh`, `syntax-check.sh`, `new-script-warning.sh`, `inbox-check.sh`, `inbox-check-mini.sh`, `pre-dispatch-gate.sh` (plus 1+ Syncthing sync-conflict copies of `pre-dispatch-gate.sh` — clean up periodically) |
| `bridge/myndaix-daemon.js` | Node v2.0 daemon |
| `factory/` | Software factory: specs, scenarios, evals, knowledge, dashboards, workflows |
| `factory/workflows/` | Per-project workflow files (currently `fieldvision.md`, `myndaix.md`) |
| `agent-knowledge/<agent>.md` | Curated per-agent persona/rules (always loaded into prompts) |
| `agent-profiles/<agent>-<profile>.json` | Tool-permission profiles (Mack uses these) |
| `memory.db` (128KB, SQLite) | Tables: `memory`, `patterns`, `tasks`, `migration_log` |
| `telemetry/tasks.jsonl` (50 MB, 248,983 lines) | Append-only event log; first entry 2026-04-25, last updated live |
| `knowledge/` | Semantic-search store (separate from factory/knowledge) — `inject-context.sh`, `query.py`, `ingest.py`, embeddings dir |
| `lobster-bot/` | Lobster's Discord notifier code + memory DB |
| `discord/.env` | 10 Discord webhook URLs (chmod 600) |
| `.secrets` | chmod 600. Contains `PERPLEXITY_API_KEY`, `GEMINI_API_KEY`, `ELEVENLABS_API_KEY`. Only `tools/cost-tracker.sh` actually sources this file. Recon's PERPLEXITY key is consumed via the recon-watcher LaunchAgent plist env block (what launchd injects); `.secrets` is the canonical inventory but is NOT sourced by recon-watcher. Oracle's `gemini` CLI uses a separate OAuth path (`~/.gemini/settings.json` → `selectedType: oauth-personal`), not GEMINI_API_KEY. ELEVENLABS has no active consumer as of 2026-05-04. The file itself documents these consumption paths inline. |

---

## 2. Agent Roster

Eight named agents, plus Smoke (automated QA) which is part of the dispatch chain.

### Lobster — orchestrator

- **Role:** routes work between agents, owns the conversation, posts to Discord
- **Engine:** Claude Code (interactive session on OpenClaw, not via watcher)
- **Watcher:** none — Lobster is interactive. `bridge/watchers/lobster-monitor.sh` (every 5 min via LaunchAgent `ai.myndaix.lobster-monitor`) watches the OpenClaw session for memory pressure / uptime drift and rotates before degradation. `bridge/watchers/discord-relay.sh` posts inbox results to Discord.
- **Discord:** `lobster-notifier` (PM2) tails `inbox/lobster/` and posts results via webhook
- **Memory:** owns `~/.myndaix/lobster-bot/lobster-memory.db` (separate from main `memory.db`)
- **Status:** see `state/lobster-session.json` for current state

### Mini — pipeline builder (always-on)

- **Role:** primary build agent; default target for Lobster's build dispatches
- **Engine:** Claude (`claude -p` via local proxy `localhost:3457` health-gated), Codex fallback (`gpt-5.3-codex`)
- **Watcher:** `bridge/watchers/mini-watcher.sh` • **Runner:** `bridge/watchers/mini-runner.sh` (shared with Antman)
- **Smart routing:** `scripts/smart-router.sh::select_model` — Haiku/Sonnet/Opus by complexity
- **Deployment:** Mini, LaunchAgent `ai.myndaix.mini-watcher`, in centralized fswatch (PID 5724)
- **Authorized senders:** `lobster mini antman mack jefe oracle recon harley notion-poller`
- **Permissions:** `--dangerously-skip-permissions`; refuses to start without 3 hooks (`branch-guard`, `destructive-blocker`, `syntax-check`); pushes branches to origin
- **Domain (memory):** `fieldvision`
- **Upgrades wired:** 1 telemetry, 2 schema+pain, 3 memory (env-var to runner), 5 SQLite queue, 6 pattern, Part A workflow (in runner)
- **Notable:** parallel-lock via `claim_task_parallel` (renamed from `claim_task` to avoid common.sh collision); branch-aware worktrees honor frontmatter `branch:`
- **Status:** see `state/mini-heartbeat.json` for current state

### Mack — hands-on MacBook builder

- **Role:** builder agent that runs on the user's MacBook for interactive collaboration
- **Engine:** Claude Code via `mack-runner.sh` with profile-based tool scoping; **Codex disabled** in `mack-runner.sh` (search "codex engine is disabled — no scoped permission support")
- **Watcher:** `bridge/watchers/mack-watcher.sh` • **Runner:** `bridge/watchers/mack-runner.sh`
- **Architecture (unique):** does NOT source `lib/common.sh` — ~25 inline copies of shared functions. Single-task per run (no drain loop). SHA256-verifies `validate.sh` before sourcing.
- **Profiles:** `agent-profiles/mack-autonomous.json` (default), `mack-protected.json` (sandboxed for `access_level: protected-context` tasks). Encrypted Knowledge Pointer System resolves `{{pointer:...}}` only in protected mode.
- **Cost logging:** writes JSONL entries to `bridge/state/cost-log.jsonl` per call (only agent that does this)
- **Output scanning:** `scripts/scan-output.sh` runs passively on every result (only agent with this)
- **Deployment:** **MacBook only.** Mini's LaunchAgent disabled (`.plist.disabled`)
- **Authorized senders:** prefers `bridge/state/trusted-senders.conf`, fallback `lobster mini jefe mack antman kilabz oracle recon harley`
- **Domain (memory):** `fieldvision`
- **Upgrades wired:** 1 telemetry, 2 schema+pain, 3 memory (now wired via inline `query_memory`), 5 SQLite queue, 6 pattern, Part A workflow (in runner). FIX 9 heartbeat parity backported.
- **Status:** dormant on Mini (disabled), unknown on MacBook (audit was machine-bound)

### Antman — cost-tier builder + second opinion

- **Role:** builds when Codex (free OAuth) is preferred; second opinion on Mini results
- **Engine:** **Codex first** (`gpt-5.3-codex`), Claude fallback. Inverse of Mini.
- **Watcher:** `bridge/watchers/antman-watcher.sh` • **Runner:** shares `mini-runner.sh`
- **Deployment:** Mini, LaunchAgent `ai.myndaix.antman-watcher`, in centralized fswatch
- **Authorized senders:** `lobster mini antman mack jefe oracle recon harley notion-poller`
- **Permissions:** Codex `--dangerously-bypass-approvals-and-sandbox`; Claude `--dangerously-skip-permissions`. **No `verify_hooks_loaded` gate** (asymmetry vs Mini, by design — Codex bypasses Claude Code hooks anyway).
- **Domain (memory):** `fieldvision`
- **Upgrades wired:** 1, 2, 3 (now wired via watcher env-var export), 5, 6, Part A (via shared runner). No `extract_knowledge` (by design for cost-tier).
- **Quarantine:** moves bad-frontmatter tasks to `bridge/quarantine/`
- **Status:** see `state/antman-heartbeat.json` for current state

### KilaBz — code reviewer

- **Role:** read-only structured code review; verdicts are advisory
- **Engine:** Codex (`gpt-5.3-codex`) primary, Gemini (`gemini-2.5-pro` CLI) fallback on rate-limit
- **Watcher:** `bridge/watchers/kilabz-watcher.sh` (no runner — inline)
- **Rubrics:** `bridge/rubrics/review-{security,correctness,style}.md` selected by `detect_review_type` from frontmatter
- **Output contract:** required format `OVERALL VERDICT: PASS|FAIL` + numbered findings `[PASS|FAIL] criterion | Evidence: file:line | Reason: ...`. Loose evidence regex (post-cleanup) accepts comma-separated cites.
- **Result frontmatter:** has both `validation:` (agent ran cleanly) and `verdict:` (review outcome) — separated so the breaker can't trip on a correctly-identified bad-code FAIL.
- **Deployment:** Mini, LaunchAgent `ai.myndaix.kilabz-watcher`, in centralized fswatch
- **Authorized senders:** `lobster mini antman mack jefe oracle recon harley`
- **Permissions:** read-only by design; codex sandbox `read-only`, post-run `git checkout -- .` discards any writes; no commits/push
- **Branch-aware:** honors frontmatter `branch:`, uses `--detach` worktree
- **Domain (memory):** `fieldvision` (queries domain + system memory in prompt)
- **Status:** see `state/kilabz-heartbeat.json` for current state

### Oracle — architecture / security review (Gemini)

- **Role:** mandatory async review on every Mini/Antman/Mack PASS result; architectural and security depth beyond KilaBz line-by-line
- **Engine:** Gemini CLI (`gemini -m gemini-2.5-pro`). The `lib/gemini-api.sh` REST wrapper still exists in the tree but oracle-watcher invokes the CLI, not the REST helper. Note: `oracle-watcher.sh`'s log line still says "Running Gemini API (direct REST, ...)" — stale log string, the CLI is what actually runs.
- **Auth:** `gemini` CLI uses Google OAuth (`~/.gemini/settings.json` → `selectedType: oauth-personal`), **not** an API key. The `GEMINI_API_KEY` in `~/.myndaix/.secrets` exists for direct REST consumers (cost-tracker, kilabz-watcher fallback); Oracle itself authenticates via the CLI's OAuth.
- **Watcher:** `bridge/watchers/oracle-watcher.sh` (sources both `common.sh` and `parallel.sh`)
- **Deployment:** Mini, LaunchAgent `ai.myndaix.oracle-watcher`
- **Authorized senders:** `lobster mini antman mack jefe kilabz recon harley oracle smoke` (broadest list — accepts dispatches from peer agents and self)
- **Branch resolution:** **fail-closed** (KilaBz P1 fix) — if `branch:` can't be resolved, rejects task with `status=blocked`. No fallback guess from subject.
- **Domain (memory):** queries fieldvision + system
- **Upgrades wired:** all (also benefits silently from the parallel.sh `claim_task_parallel` rename — its 1-arg SQLite claim now works correctly)
- **Status:** see `state/oracle-heartbeat.json` for current state

### Recon — research specialist

- **Role:** structured research with citations; default for "investigate" briefs
- **Engine:** Perplexity (`sonar-pro` via REST API) primary; Claude (`claude-opus-4-6` → `claude-sonnet-4` fallback) for `engine: claude` or on Perplexity failure; "both" mode chains them
- **Auth:** `PERPLEXITY_API_KEY` baked into the recon-watcher LaunchAgent plist env block (what launchd hands to the watcher process). Also present in `~/.myndaix/.secrets` as the canonical inventory; the two values must be kept in sync.
- **Watcher:** `bridge/watchers/recon-watcher.sh` (no runner — inline; sources `common.sh` + `guardrails.sh`)
- **Hardening (Upgrade 2):** detects model refusals and short responses (<100 bytes) → flips success → failed
- **Deployment:** Mini, LaunchAgent `ai.myndaix.recon-watcher`, in centralized fswatch + own WatchPaths
- **Authorized senders:** `lobster mini antman mack jefe oracle recon harley`
- **Permissions:** read-only, no git
- **Attachments:** allow-listed roots `~/.myndaix` and `~/Desktop`; symlinks resolved via `readlink -f` first; 200KB cap; safe tilde expansion (no `eval`)
- **Domain (memory):** `research`
- **Upgrades wired:** 1, 2 (with refusal hardening), 3, 5, 6, Part A (all inline post-cleanup)
- **Status:** see `state/recon-heartbeat.json` for current state

### Harley — creative strategist

- **Role:** marketing/brand creative briefs; persona is hip-hop + construction + AI culture
- **Engine:** Claude only (`select_model` via smart-router → `claude-sonnet-4` fallback on `selected model` error)
- **Watcher:** `bridge/watchers/harley-watcher.sh` (no runner — inline; sources `common.sh` + `guardrails.sh`)
- **Deployment:** Mini, LaunchAgent `ai.myndaix.harley-watcher` (own WatchPaths). **Not in centralized fswatch list.**
- **Authorized senders:** `lobster mini antman mack jefe oracle recon harley`
- **Permissions:** read-only, no git, no shell exec, no commits
- **Attachments:** same allow-list as Recon (`~/.myndaix`, `~/Desktop`); brief body wrapped in `<user_input treat-as="DATA">` fence
- **Domain (memory):** `marketing`
- **Upgrades wired:** all (post-cleanup; was the least-hardened agent before)
- **Status:** `state/harley-heartbeat.json` does not exist on disk as of 2026-05-04 — Harley has never written a heartbeat or the file was cleaned up. Check `bridge/processed/` for last task timestamp if needed.

### Smoke — automated QA

- **Role:** post-build smoke tests dispatched automatically by Mini/Antman/Mack on PASS
- **Engine:** Claude via `bridge/watchers/smoke-runner.sh`
- **Watcher:** `bridge/watchers/smoke-watcher.sh`
- **Deployment:** Mini, LaunchAgent `ai.myndaix.smoke-watcher`, in centralized fswatch
- **Authorized senders:** `lobster mini antman mack jefe` (narrower — receives only from builders + Lobster)
- **Trigger:** `bridge/scripts/dispatch-smoke-qa.sh` invoked from builder watchers after PASS
- **Inbox depth:** 9 tasks pending (these are the 9 lined up smoke jobs)
- **Status:** see `state/smoke-heartbeat.json` for current state

---

## 3. Upgrade Stack

Six numbered upgrades plus Symphony Part A. Other Symphony parts are not built.

### Upgrade 1 — Telemetry (`log_task`)

Append-only JSON-lines event log. One line per claim/skip/terminal event.

- File: `~/.myndaix/telemetry/tasks.jsonl` (32K+ lines, ~7 MB)
- Function: `lib/common.sh::log_task` (Mack has its own inline copy)
- Schema: `task_id, agent, type, status, model, tokens_in, tokens_out, error, timestamp`
- Wired: all agents

### Upgrade 2 — Schema + Pain (`validate_task`, `check_pain`)

- `validate_task` (`common.sh::validate_task`): require `from, to, type, subject`; type ∈ `task|review|research|creative`. Reject → move to `bridge/rejected/`.
- `check_pain` (`common.sh::check_pain`): rolling 1h grep of `tasks.jsonl` for `"status":"failed"` per agent. ≥3 → write `state/<agent>-paused` flag and pain-alert to Lobster.
- Recon adds **refusal/short-response detection** in `recon-watcher.sh` (search for "HARDENING" / refusal flip) flipping `success → failed`.
- Wired: all agents

### Upgrade 3 — Memory (`query_memory` / `save_memory`)

- Store: `~/.myndaix/memory.db`, table `memory` with columns including `domain, category, content, evidence, confidence, last_accessed, access_count, deprecated`
- `query_memory` (`common.sh::query_memory`): READ — bumps `last_accessed` and `access_count`, returns top-N by confidence
- `save_memory` (`common.sh::save_memory`): WRITE — used **only by pattern detection**, not by agents directly (decision)
- Counts (deprecated=0): `fieldvision: 140`, `system: 23`, `research: 15`, `marketing: 9`
- Wired: all agents post-cleanup. Mini and Antman query in watcher and export to runner via env vars; KilaBz, Oracle, Recon, Harley, Mack query inline.

### Upgrade 5 — Task Queue (`claim_task` / `complete_task`)

- Store: `~/.myndaix/memory.db` table `tasks`. Atomic claim via `UPDATE ... WHERE id IN (SELECT ... LIMIT 1) RETURNING ...`.
- Function: `lib/common.sh::claim_task` (1-arg, agent name)
- **Collision-resolved:** `lib/parallel.sh` previously defined a same-named function (2-arg per-task lock). Renamed to `claim_task_parallel` / `release_task_parallel` (2026-05-04). Two callers updated: `mini-watcher.sh`. Oracle silently benefited (its 1-arg call now correctly resolves to common.sh).
- Wired in parallel with file inbox; SQLite preferred when row exists, file inbox is fallback.

### Upgrade 6 — Pattern Detection

- `detect_pattern` (`common.sh::detect_pattern`) — sha256 fingerprint of `agent|type|repo|top-3-keywords`, dedupe + occurrence count
- `detect_failure_pattern` — same with `F` prefix
- Auto-promotes to Lobster as proposal at 3+ occurrences
- Current state: 23 patterns. Top: `pattern 4` (Oracle lint_rule, 19 occurrences, **promoted=1**), `pattern 6` (Mini prompt_improvement, 9 occurrences, promoted=1), `pattern 12` (KilaBz failure, 7 occurrences)
- Wired: all agents

### Symphony Part A — Workflow Injection

- `bridge/scripts/agent-dispatch.sh` (helpers `resolve_agent_role`, `find_workflow_file`, `_wf_block`): when an agent dispatches to another via this script, looks up `factory/workflows/<project>.md` by repo (longest-prefix match), extracts `### <Role>` and `### Outside counsel integration` sections, appends to task body as `## Workflow Context (project)`.
- Roles map: `mini|mack|antman → Build agents`, `kilabz → Review agents`, `oracle → Architecture review`, `recon → Research`, `harley → Creative`.
- Runners/watchers also do the lookup themselves (post-cleanup) for tasks dispatched directly to inbox by Lobster (which doesn't go through agent-dispatch.sh). De-dup guard via `grep -q '^## Workflow Context'`.
- Wired everywhere.

### Self-healing (`lib/self-healing.sh`)

- Failure classification: `TIMEOUT, ENGINE_ERROR, VALIDATION, PERMISSION, UNKNOWN`
- Per-class retry budget; escalation to Lobster on exhaustion
- Used by Mini, Antman, KilaBz, Oracle, Smoke (sourced in their watchers)

---

## 4. Factory Structure

Source of truth: `~/.myndaix/factory/README.md`. Workflow:

> Spec → Scenario → Dispatch → Build → Validate → Eval → Ship → Learn

```
factory/
├── README.md               (factory-wide rules)
├── workflows/              per-project, per-role agent instructions
│   ├── fieldvision.md      (id: WORKFLOW-FV; repo: ~/code/active/fieldvision)
│   └── myndaix.md          (id: WORKFLOW-MX)
├── specs/                  what to build
│   ├── fieldvision/
│   │   └── FV-OFFLINE-SYNC.md
│   └── myndaix/            (empty)
├── scenarios/              what "done" looks like (referenced by specs)
│   ├── fieldvision/
│   │   └── offline-report-capture.md
│   └── myndaix/
├── evals/                  test harnesses + run results
│   ├── fieldvision/
│   │   └── offline-capture-smoke.md
│   ├── myndaix/
│   └── runs/
│       └── 2026-05-01-offline-capture-001.md
├── knowledge/
│   ├── patterns/           PAT-*.md (proven approaches)
│   ├── runbooks/           RB-*.md (recurring procedures)
│   └── postmortems/        PM-YYYYMMDD-*.md (failure narratives)
└── dashboards/
    └── factory-status.md
```

### Frontmatter schemas

**Workflow file** (`factory/workflows/<project>.md`):
```yaml
id: WORKFLOW-XX
project: <name>
repo: <path>
language: <swift|typescript|...>
framework: <ios/swiftdata|next.js|...>
branch_strategy: <description>
review_required: true|false
reviewers: [kilabz, oracle, ...]
eval_required: true|false
deploy_target: <testflight|vercel|...>
specs_dir: ~/.myndaix/factory/specs/<project>/
scenarios_dir: ~/.myndaix/factory/scenarios/<project>/
```
Body sections: `### Build agents`, `### Review agents`, `### Architecture review`, `### Research`, `### Creative`, `### Outside counsel integration`. Watchers extract by exact role name match.

**Spec file** (`factory/specs/<project>/<ID>.md`):
```yaml
id: <PROJ-NAME>
title: <human title>
status: draft|active|shipped
project: <name>
author: jefe
reviewers: [oracle, kilabz]
priority: p0|p1|p2|p3
scenarios:
  - "[[scenarios/<project>/<scenario-id>]]"
acceptance:
  - <criterion 1>
  - <criterion 2>
tags: [...]
```

### Connection rules

- A spec lists scenarios via wikilinks → reviewers must check both
- A scenario references one or more evals
- An eval run produces a row in `evals/runs/<date>-<id>.md` with pass/fail evidence
- Postmortems link back to the spec or task that broke
- Patterns (in DB and `factory/knowledge/patterns/`) accumulate from multiple successful tasks; promoted at 3+ occurrences

---

## 5. Communication Flow

### Task dispatch → result

```
Lobster decides to dispatch
    │
    ├── direct write to inbox/<agent>/<ts>-lobster-to-<agent>-<slug>.md
    │   (no workflow injection — Lobster doesn't go through agent-dispatch.sh)
    │
    └── via scripts/agent-dispatch.sh (peer-to-peer)
        └── injects workflow context into body before write
            │
            ▼
inbox/<agent>/  ──fswatch event──►  daemon (myndaix-daemon.js, PM2-managed)
                                        │
                                        ▼
                                  spawn watcher
                                        │
                                        ▼
            ┌───── watcher script ─────┐
            │  acquire_lock            │
            │  pause check (top)       │
            │  claim_task (SQLite)     │
            │  validate_task           │
            │  sender allowlist        │
            │  tier check              │
            │  size cap                │
            │  check_dedupe            │
            │  budget gates            │
            │  ensure repo/branch      │
            │  query_memory → env      │
            │  invoke runner ──────────┼──► claude/codex/gemini/perplexity
            │  capture stdout/stderr   │
            │  classify VALIDATION     │
            │  commit + push (builders)│
            │  write result            │
            │  dispatch_next (chain)   │
            │  Oracle dispatch (if PASS)
            │  Smoke dispatch (if PASS, builders)
            │  archive_task            │
            │  log_task (terminal)     │
            │  write_heartbeat         │
            │  check_pain              │
            │  detect_pattern          │
            └──────────────────────────┘
                                        │
                                        ▼
inbox/lobster/<ts>-<agent>-result.md  ──►  lobster-notifier (PM2)
                                              │
                                              ▼
                                         Discord webhook
```

### SQLite queue ↔ file inbox

Both run in parallel. When a watcher fires, it tries SQLite `claim_task` first; if no row, falls back to `pick_oldest_task` from the inbox dir. Tasks dispatched via `bridge-send.sh` and similar can land in either; both paths converge at the watcher's processing logic.

### Outside counsel gate

Symphony Part A injects `### Outside counsel integration` workflow sections into task contexts. **An actual gating mechanism (Part B) is not built.** Currently the section is informational text shown to the agent — there's no code that withholds dispatch pending counsel sign-off.

### Discord integration points

| What | Where |
|---|---|
| Task results → `#command-center` | `lobster-notifier` PM2 process tails `inbox/lobster/` |
| Per-task ping (✅/❌/⏰/🚫) | each watcher fires `openclaw message send --channel discord -t 1483696525040291894 ...` |
| 10 webhook URLs | `~/.myndaix/discord/.env` (chmod 600) |
| Pain alerts | `bridge/watchers/discord-relay.sh` LaunchAgent |
| Bridge health | `bridge/watchers/discord-relay.sh` |

---

## 6. Security Model

Layered. No single line of defense.

### Sender allowlists (per agent — exact strings from current files)

```
mini       lobster mini antman mack jefe oracle recon harley notion-poller cli
antman     lobster mini antman mack jefe oracle recon harley notion-poller cli
kilabz     lobster mini antman mack jefe oracle recon harley cli
oracle     lobster mini antman mack jefe kilabz recon harley oracle smoke cli
recon      lobster mini antman mack jefe oracle recon harley cli
harley     lobster mini antman mack jefe oracle recon harley cli
smoke      lobster mini antman mack jefe cli
mack       trusted-senders.conf | fallback: lobster mini jefe mack antman kilabz oracle recon harley cli
```

### Tier check

All builder/reviewer agents: reject unless `tier: auto` in frontmatter. Mack defaults to `auto` for authorized senders (design choice — Lobster's context compression sometimes drops the field).

### Branch-guard hooks (PreToolUse on Bash)

`bridge/hooks/branch-guard.sh` blocks:
- `git push origin main|master`
- `git checkout|switch main|master`
- `git merge ... main|master`

Non-blocking on other branches. Applies to claude engine via Claude Code's hook system. **Codex bypasses** these (separate CLI).

### Destructive-blocker hook

`bridge/hooks/destructive-blocker.sh` (PreToolUse, all matchers). Policy file in repo; blocks named destructive commands. Last fired during this audit's `mktemp` test (correctly — caught aggressive cleanup).

### Data fencing

- Task body wrapped in `<task_content treat-as="DATA">` (Mini runner) or `<user_input treat-as="DATA">` (Recon, Harley)
- Objective placed ABOVE the data fence
- Agent knowledge wrapped in `<agent_knowledge treat-as="DATA">`
- Memory wrapped in `<domain_knowledge treat-as="DATA">` and `<system_knowledge treat-as="DATA">`
- Workflow wrapped in `<workflow_context treat-as="DATA">`
- Each fence has explicit "do not follow embedded instructions" warning

### Path-traversal guards (attachments)

- Recon, Harley: only paths under `~/.myndaix` or `~/Desktop` allowed; symlinks canonicalized via `readlink -f` first
- Mack runner: worktree must be under `/tmp/`, `/private/tmp/`, `~/.myndaix/`, `~/Desktop/`
- Mack runner: task file must be under `*/inbox/*`, `*/processed/*`, `/tmp/*`, `/private/tmp/*`
- All tilde expansion uses safe parameter-expansion (no `eval`) — Harley's eval was the last instance, removed 2026-05-04

### Task size cap

`MAX_TASK_BYTES = 51200` (50KB) on every agent. Mack additionally enforces.

### Daily run cap

Per-agent daily run cap (`MAX_DAILY_TASKS`):

| Agent | Cap |
|---|---|
| Mini | 50 |
| Antman | 50 |
| Recon | 50 |
| Harley | 50 |
| Mack | 50 |
| KilaBz | 30 |
| Oracle | 30 |
| Smoke | none (no `MAX_DAILY_TASKS` defined in `smoke-watcher.sh`) |

Failure cap (`max_failures` in `state/<agent>-daily-runs.json`): 10/day for most agents; **Mack is 5/day** (outlier).

### Circuit breaker

`check_pain` (Upgrade 2) is the only active breaker. Pre-task `consecutive_failures` heartbeat gate was dead code in every agent — removed in cleanup. `check_pain` writes `state/<agent>-paused` flag; watchers gate on it BEFORE claiming a task (post-cleanup).

### Profile-based tool scoping (Mack only)

`agent-profiles/<agent>-<profile>.json` defines `permissions.allow` and `permissions.deny`. Mack-runner passes these as `--allowedTools` and `--disallowedTools` to claude. Profiles validated regex `[a-zA-Z0-9_-]` and realpath-checked to prevent traversal.

### Encrypted Knowledge Pointer System (Mack only)

`access_level: protected-context` in frontmatter forces `mack-protected` profile and resolves `{{pointer:...}}` tokens via `scripts/resolve-pointers.sh`. `access_level: unrestricted-tools` strips pointer tokens without resolving. Mutually exclusive; fail-closed on invalid value.

---

## 7. Known Deferred Items

### Cleanup-week deferrals (by-design)

| Agent | Item | Reason |
|---|---|---|
| Antman | A8: no `extract_knowledge` hook | by-design for cost-tier (doesn't accumulate learnings) |
| Antman | A9: no `verify_hooks_loaded` gate | Codex-first path bypasses Claude Code hooks anyway |
| Recon | no retry budget / dead-letter | research isn't worth auto-retrying |
| Recon | API key in plist | low-medium risk, plist is user-owned. Now also documented in `~/.myndaix/.secrets` (auth inventory); plist remains the actual launchd-injected value. |
| Recon | quarantine name collision | rare in practice |
| Harley | `repo` field referenced but not extracted | cosmetic — Oracle dispatch passes empty repo, doesn't matter for creative output |
| Harley | daemon heartbeat declares "watching: harley" but actual fswatch process doesn't | LaunchAgent's own WatchPaths covers it; cosmetic mismatch |
| Mack | tier defaults to "auto" if missing | intentional — Lobster's context compression drops the field |
| Mack | wrong-machine path translation is one-way only | Mack-on-Mini deployment unsupported by design (now disabled) |

### Pending Symphony

- **Part B — counsel gate:** workflow files have `### Outside counsel integration` sections that watchers extract and inject as informational. **No actual gate** — no code blocks dispatch on missing sign-off. Designed but not built.
- **Part C / Part D:** referenced nowhere in code. Not started.

### Pattern 4 (Oracle lint_rule, promoted)

DB row: `id=4, fingerprint=e4b1844cf84f60fa, occurrences=10, agent=oracle, recommended_type=lint_rule, promoted=1`. Promotion alert was sent to Lobster (`promotion-4-*.md`). **The actual lint rule was never implemented.** The pattern is "promoted" in the sense that the system flagged it; no code change followed.

### KilaBz format-validator

Only present as the error string `FORMAT_VALIDATION_FAILED` in `kilabz-watcher.sh`. The deferral is: **Codex output is non-deterministic and the loose evidence regex (post 2026-05-04 fix) accepts almost any structured finding line.** A stricter, dedicated format-validator (separate from the regex) is P0 but not built.

### Mack common.sh migration

Mack maintains ~25 inline copies of common.sh functions. `write_heartbeat` had already drifted (FIX 9 missed) and `check_pain` heredoc escaping was mangled — both backported during cleanup. Open question: migrate to sourcing common.sh (with overrides for Mack-specific helpers) or keep inline for portability. Decision deferred.

### ~~myndaix-daemon PM2 restart loop~~ — RESOLVED 2026-05-04

PM2 had logged 48,573 restarts because both LaunchAgent (`ai.myndaix.daemon`) and PM2 tried to start the daemon. **Resolution:** LaunchAgent unloaded and the plist moved to `~/Library/LaunchAgents/disabled/ai.myndaix.daemon.plist`. PM2 reset; daemon is now online with restart count 0 and PM2 is the sole process manager. See Section 1 (PM2 processes + Disabled LaunchAgents).

---

## 8. Key Decisions Log

In approximate chronological order, with the rationale that's load-bearing for future agents.

**Oracle uses Gemini CLI, not REST.** The `lib/gemini-api.sh` REST wrapper still exists in the tree but is no longer invoked by `oracle-watcher.sh` (the watcher calls the `gemini` CLI directly). The file has no formal deprecation marker; treat it as dead code pending removal. CLI handles auth and rate limiting more cleanly than direct curl.

**Mack is MacBook-only.** Inline functions exist because Mack was originally designed before `common.sh`. Mini deployment was a wrong-deploy artifact (path translation went the wrong direction). LaunchAgent is now `.plist.disabled`. The MacBook deployment runs separately.

**Memory: read-only for agents, write-only via pattern detection.** Agents call `query_memory`; nobody calls `save_memory` directly. New memory entries flow through `detect_pattern` once an occurrence count crosses threshold. This avoids agents poisoning memory with self-justifying entries.

**Workflows are per-project, per-role, injected at dispatch.** A task targeting `repo: ~/code/active/fieldvision` gets the `fieldvision.md` workflow's `### Build agents` (or `### Review agents`, `### Research`, etc.) section pulled in. Two routes inject: `agent-dispatch.sh` (when one agent dispatches to another) and the watcher/runner itself (when Lobster dispatches directly).

**Validation vs verdict: separate fields.** Result frontmatter uses `validation:` for "did the agent itself run cleanly" and `verdict:` for "did the code pass review." The breaker (`check_pain`) keys off `validation` so a correctly-identified bad-code FAIL never trips the breaker. Lobster reads `verdict` for the actual review outcome.

**Parallel run: SQLite queue primary, file inbox fallback.** Watchers try `claim_task` against `memory.db tasks` table first; if no row, fall back to `pick_oldest_task` on the inbox dir. Tasks can land via either path; both converge.

**`claim_task_parallel` rename (2026-05-04).** `lib/parallel.sh::claim_task` previously overrode `lib/common.sh::claim_task` because it was sourced last. Renamed parallel.sh's version to `_parallel` so both can coexist. Affected: mini-watcher (callers updated), oracle-watcher (silently fixed — its 1-arg call now correctly resolves to common.sh's SQLite version).

**Pause check before claim, exit not continue.** Standard pattern across all agents post-cleanup. Pause flag is checked at the top of the drain loop (or top of single-task run for Mack); on hit, watcher exits cleanly so fswatch can re-fire when the pause is cleared. Previously pause check ran AFTER claim, leaving orphan "claimed" rows in telemetry.

**Branch-aware worktrees.** Mini, Antman, KilaBz, Mack honor frontmatter `branch:` — checkout existing branch (local → fetch+remote), create fresh as last resort. Falls back to auto-generated `<agent>/<slug>` when frontmatter has no branch. KilaBz uses `--detach` (read-only review); builders use the branch directly so commits push back to the intended feature branch.

**Heartbeat: terminal-state guard + daily reset (FIX 9).** `lib/common.sh::write_heartbeat` only increments `tasks_today` for terminal statuses (pass/failed/timeout/skipped/etc.) and resets the counter on UTC date rollover. Fixed across the fleet 2026-05-04. Mack's inline copy was backported.

**Codex disabled in Mack runner.** `mack-runner.sh` errors with "codex engine is disabled — no scoped permission support. Use claude engine." Mack relies on profile-based `--allowedTools` which only Claude Code supports.

**Engine inversion for Antman:** Codex first (free OAuth), Claude fallback. Lets Antman run cheaply as second-opinion or background builder while Mini is on a paid Claude API.

---

*End of manifest. If something here is wrong or out of date, fix it directly — don't write parallel docs.*
