# MyndAIX Bridge

> Your codebase is already on disk. `grep` is free. `sqlite3` is free. `find` is free.
> Why are you paying per-token to have an API rediscover what your filesystem already knows?

A multi-agent AI team built on bash, SQLite, markdown, and inexpensive CLI tools — **no frameworks, no SDKs, no vendor lock-in**. Eight specialized agents coordinate through a file-based message bus on a single Mac (or two), running 24/7 for ~$20–50/month plus an existing Mac.

The agents in this repo don't pay an LLM to enumerate files, parse JSON, or remember yesterday's decisions — those are bash, jq, and SQLite jobs. LLMs are reserved for the things only LLMs can do: judgment, code, prose. Everything below this line should be read as a worked example of that principle.

---

## Quick start

```bash
git clone https://github.com/MyndAIX/myndaix-bridge-oss ~/.myndaix/bridge
cd ~/.myndaix/bridge

# 1. Secrets template
cp .secrets.example ~/.myndaix/.secrets && chmod 600 ~/.myndaix/.secrets
$EDITOR ~/.myndaix/.secrets

# 2. Memory DB
mkdir -p ~/.myndaix && sqlite3 ~/.myndaix/memory.db < schema.sql

# 3. Safety hooks (CRITICAL — agents that invoke `claude` need these)
bash scripts/install-claude-hooks.sh

# 4. Watchers (LaunchAgent templates)
bash scripts/install-launch-agents.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.myndaix.*.plist

# 5. Daemon
pm2 start ecosystem.config.js && pm2 save

# 6. Dispatch your first task
./scripts/dispatch.sh \
  --to mini --from cli \
  --subject "say hello" \
  --objective "echo a friendly message" \
  --priority P3 --scope-in "/tmp" --done "Output is non-empty" \
  --body "echo hello from mini"

# Watch the result land:
tail -f ~/.myndaix/bridge/inbox/lobster/*.md
```

End-to-end milestone: **first task in 5 minutes**. Full setup walkthrough in [`SETUP.md`](SETUP.md).

---

## The team

Eight named agents, each specialized for a role. Engines and roles are wired in `watchers/<agent>-watcher.sh`.

| Agent | Role | Engine | Accepts |
|---|---|---|---|
| **Lobster** 🦞 | Orchestrator — strategy, oversight, coordination, relay | Claude Opus | `message` |
| **Mini** | Pipeline builder | Claude Opus 4.6 | `task` |
| **Mack** | Hands-on builder (peer machine) | Claude Opus 4.6 | `task` |
| **Antman** | Builder + second opinion | GPT-5.3 Codex | `task` |
| **KilaBz** | Code reviewer (read-only) | GPT-5.3 Codex | `task`, `review` |
| **Recon** | Research agent | Claude / Perplexity | `research` |
| **Harley** 🎨 | Creative strategist | Claude Code | `task` |
| **Oracle** 🔮 | Third-eye reviewer (vision + arch) | Gemini 2.5 Pro | `review` |

Failover routing: Antman → Mack, KilaBz → Lobster, Mack → Antman.

---

## Three orchestration tiers

You don't need all of it. Each tier is a complete stopping point.

| Tier | What you get | Required setup |
|---|---|---|
| **Level 1 — CLI dispatch** (5 min) | `scripts/dispatch.sh --to mini --from cli …` writes a task; watcher picks it up; result lands in `inbox/lobster/`. You read results manually. | Clone + secrets + LaunchAgents + hooks. |
| **Level 2 — OpenClaw + Discord** | Lobster receives commands via Discord `#command-center`, routes to agents, relays results back. | Tier 1 + Discord bot + OpenClaw gateway. |
| **Level 3 — Factory pipeline** | Spec-driven autonomous build loop: spec → Oracle review → Mini build → KilaBz review → Oracle architecture review. | Tier 1 + populate `factory/` specs. |

Tier 1 is what makes this repo different from frameworks: a fresh clone gives you a working multi-agent system that responds to a terminal command. No Discord, no SDK, no orchestrator service to register. See [`SETUP.md`](SETUP.md) for the per-tier walkthrough.

---

## Recent shipped upgrades

From `git log` on `main` (most recent first):

- **Manifest drift patch** (`2b1fc7b`) — reconciled SYSTEM-MANIFEST.md against the live LaunchAgent set after week-1 cleanup.
- **Oracle fail-closed branch resolution + from-allowlist** (`b72b451`) — review tasks without an explicit `branch:` are now rejected rather than silently routed to `main`.
- **SQLite-backed dashboard** (`5163b4a`) — Upgrade 7 Part C: terminal status board reads directly from `memory.db` instead of crawling `processed/`.
- **Per-project WORKFLOW.md dispatch** (`8cf6507`) — `factory/workflows/<project>.md` is matched longest-prefix against the dispatch's repo path, so multi-project setups get the right agent chain.
- **Pattern detection auto-promotion** (`824dc24`) — Upgrade 6: outcomes seen ≥3 times graduate from the `patterns` table to durable memory.
- **SQLite task queue** (`ac25f0b`, `db7001b`) — Upgrade 5: atomic claim via `UPDATE ... WHERE status='pending' RETURNING`, parallel to the file-based inbox.
- **Memory injection into prompts** (`10a7a4e`) — Upgrade 3 Part 2: agents see relevant prior memory at task time, with confidence-weighted ranking.

---

## The OACL framework

The system implements a seven-step control loop. Each step maps to a shipped upgrade:

| OACL step | Implemented as |
|---|---|
| **O**bserve | Telemetry (Upgrade 1) — `log_task` writes append-only events to `~/.myndaix/telemetry/tasks.jsonl` |
| **F**rame | Schema validation (Upgrade 2) — `scripts/validate-task.sh` + `validate_task` lib |
| **S**elect | Smart router (`scripts/smart-router.sh`) + `scripts/auto-router.sh` |
| **E**xecute | Per-agent watcher → runner (Mini / Mack have separate runners) |
| **V**alidate | Pain check (Upgrade 2) — `check_pain` rolling failure count, agent paused at threshold |
| **R**einforce | Memory (Upgrade 3) — confidence decay in `memory.db` |
| **U**pgrade | Pattern detection (Upgrade 6) — auto-promote at 3+ occurrences |

**No reinforcement without validation. No memory without proof. No automation without repeated success.** Each upgrade implements a layer of this loop; the absence of any step means the system can't learn safely.

---

## Project structure

```
~/.myndaix/bridge/
├── README.md                  this file
├── SETUP.md                   step-by-step install (per tier)
├── ARCHITECTURE.md            deep-dive design rationale
├── SYSTEM-MANIFEST.md         canonical reference (snapshot 2026-05-04)
├── LICENSE                    MIT
├── schema.sql                 memory.db DDL
├── ecosystem.config.js        PM2 config (daemon only)
├── .secrets.example           secrets template (chmod 600 after copy)
├── .claude/settings.json      project-local PreToolUse hook registration
├── .gitignore                 includes runtime-state dirs (state/, processed/, etc.)
│
├── scripts/                   dispatch + maintenance scripts
│   ├── dispatch.sh            Tier-1 CLI entry — schema-enforced task writer
│   ├── install-claude-hooks.sh
│   ├── install-launch-agents.sh
│   ├── auto-router.sh         routes inbox/dispatch/ to per-agent inboxes
│   ├── dashboard.sh           SQLite-backed status board
│   └── …                      smart-router, validate-task, scan-inbound, etc.
│
├── watchers/                  per-agent watchers + shared lib
│   ├── lib/                   common.sh, parallel.sh, knowledge.sh,
│   │                          guardrails.sh, self-healing.sh, etc.
│   ├── mini-watcher.sh        + mini-runner.sh
│   ├── mack-watcher.sh        + mack-runner.sh
│   └── …                      antman, kilabz, oracle, recon, harley, smoke
│
├── hooks/                     Claude Code PreToolUse hooks
│   ├── branch-guard.sh        block git push to main/master
│   ├── destructive-blocker.sh block rm -rf, DROP TABLE, git reset --hard origin
│   ├── syntax-check.sh        bash -n before exec
│   └── pre-dispatch-gate.sh   keyword scan on dispatch commands
│
├── factory/                   spec-driven build loop (Tier 3)
│   ├── README.md              the framework
│   ├── specs/                 what to build
│   ├── scenarios/             how it should behave
│   ├── evals/                 acceptance criteria + scorecard
│   ├── workflows/             agent choreography per project
│   └── knowledge/             patterns, runbooks, postmortems
│
├── launchd/templates/         LaunchAgent .plist templates with placeholders
└── examples/, rubrics/, docs/ reference material
```

Runtime state (`state/`, `state-v2/`, `processed/`, `inbox/`, `queue/`, `logs/`, `acks/`, `locks/`, `quarantine/`, `dead-letter/`) is gitignored — the repo ships only the code, not your accumulated agent history.

---

## Cost

| Component | Monthly cost |
|---|---|
| Mac (any model, M1+) | one-time, ≥ $600 |
| Claude Pro / Pro Max | $20 / $100 |
| OpenAI Plus or Codex CLI | $20 (optional, for KilaBz/Antman) |
| Gemini CLI | $0 — free tier sufficient for Oracle |
| Perplexity API | $5–20 (Recon usage-based) |
| OpenClaw + Discord | $0 |
| **Total recurring** | **~$25–140/month** depending on tier |

Per-token API costs are minimized by design: agents read files with `cat`/`grep`, query SQLite for memory, and only pay tokens when reasoning is required.

---

## Where to read next

- New users: **[`SETUP.md`](SETUP.md)** for the install walkthrough.
- Curious about why bash over a framework: **[`ARCHITECTURE.md`](ARCHITECTURE.md)** § Design philosophy.
- Reference snapshot of the system as it ran on 2026-05-04: **[`SYSTEM-MANIFEST.md`](SYSTEM-MANIFEST.md)**.
- Spec-driven Tier-3 work: **[`factory/README.md`](factory/README.md)**.

---

## License

MIT. See [`LICENSE`](LICENSE).

---

## Acknowledgments

The construction-management metaphor (GC + specialists, work reviewed before it ships, team learns from every job) shaped most of the agent-routing decisions. Thanks to seven years of running residential crews in Los Angeles for teaching the patterns this code re-implements.
