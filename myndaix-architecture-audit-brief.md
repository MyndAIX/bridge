# MyndAIX Architecture Audit Brief
## For External Review — April 2026

---

## What This Is

MyndAIX is a multi-agent AI system that builds production software. 8 specialized AI agents across 3 model families (Claude, GPT/Codex, Gemini) coordinated through file-based message passing on consumer hardware (Mac Mini + MacBook). The system shipped FieldVision — a live iOS app on the App Store — with zero human employees.

We're requesting an architecture review because we have recurring reliability issues that we keep patching instead of solving structurally. We want an outside perspective on whether the failures are implementation bugs or architectural flaws.

---

## Architecture Overview

### Machines & Network
| Machine | Role | User | Tailscale IP |
|---------|------|------|-------------|
| Mac Mini | Always-on agent host (Lobster, Mini, Antman, KilaBz, Recon, Oracle, Harley) | `jefe` | <MINI_TAILSCALE_IP> |
| MacBook | user's workstation (Mack interactive + autonomous) | `stevenfernandez` | <MACBOOK_TAILSCALE_IP> |

Syncthing keeps `~/.myndaix/bridge/` in sync bidirectionally between machines.

### The 8 Agents
| Agent | Model | Engine | Role |
|-------|-------|--------|------|
| Lobster | Claude Opus | OpenClaw gateway | Orchestrator — dispatches tasks, coordinates team |
| Mini | Claude Opus 4.6 | Claude Code CLI | Pipeline builder (always-on) |
| Mack | Claude Opus 4.6 | Claude Code CLI | Hands-on builder with founder + autonomous mode |
| Antman | GPT-5.3 Codex | Codex CLI | Builder + second opinion |
| KilaBz | GPT-5.3 Codex | Codex CLI (Gemini fallback) | Code reviewer (read-only intent) |
| Recon | Claude + Perplexity | Claude Code CLI + Perplexity API | Research specialist |
| Oracle | Gemini 2.5 Pro | Gemini CLI | Architecture/security reviewer |
| Harley | Claude | Claude Code CLI | Creative strategist |

### Communication Protocol
- Agents communicate via markdown files with YAML frontmatter
- Each agent has an inbox directory: `~/.myndaix/bridge/inbox/{agent}/`
- Tasks are dispatched by writing `.md` files to the target agent's inbox
- A daemon (`myndaix-daemon.js`) watches all inboxes via `fs.watch`
- Per-agent watcher scripts (`{agent}-watcher.sh`) process incoming tasks
- Results are written back to the sender's inbox
- Processed tasks are archived to `processed/`
- Failed/suspicious tasks go to `dead-letter/`

### Task Lifecycle
1. Lobster (or any authorized agent) writes a task `.md` to `inbox/{target}/`
2. Daemon detects new file via fs.watch
3. Target agent's watcher validates YAML frontmatter (schema, sender auth, scope)
4. Watcher creates a git worktree for isolation
5. Watcher invokes the appropriate CLI (Claude Code, Codex, Gemini) with scoped permissions
6. CLI executes the task, commits changes
7. Watcher writes result to sender's inbox
8. Original task archived to `processed/`

### Scoped Permissions
Each agent has a JSON permission profile at `~/.myndaix/agent-profiles/{profile}.json`:
- Enumerates allowed tools (Read, Edit, Bash(git status), etc.)
- Enumerates denied tools (Bash(rm -rf:*), Bash(curl:*), shell interpreters, etc.)
- Claude Code runs with `--permission-mode dontAsk --allowedTools`
- Codex runs with `--full-auto --ephemeral`

### Security Layers
- YAML frontmatter validation (schema + sender auth)
- Injection scanning (58+ regex patterns in patterns.yaml)
- Content fencing (`<task_content>` tags with DATA-only instruction)
- Scoped permission profiles per agent
- Quarantine directory for suspicious files
- Dedupe guard (prevents replay attacks)

### Monitoring
- `lobster-monitor.sh` runs every 5 min via LaunchAgent
- Checks: OpenClaw RSS memory, CPU time, uptime, session file size
- Auto-rotates Lobster session when thresholds exceeded
- Bridge health check: agent heartbeats, inbox backlog, last task status
- Cost tracking: JSONL log of token usage per task per agent
- Daily digest to Discord #alerts

---

## Known Bug List (from internal audit, April 12 2026)

### Category 1: Broken Observability
| Bug | Details |
|-----|---------|
| Mini watcher log missing | `/tmp/mini-watcher.log` does not exist — zero visibility |
| Daemon logs missing | `/tmp/myndaix-daemon-stderr.log` and stdout both absent |
| Cost tracking broken for Oracle | All Gemini entries show `input_tokens: 0, output_tokens: 0, cost_usd: 0` |
| Events log broken | `events.jsonl` entries all show `tool_name: unknown` |
| Heartbeat state never updates | `heartbeat-state.json` shows `lastSeen: ""` for all agents, `lastChecks` all null |
| Daemon heartbeat stale | Last daemon heartbeat was April 4 — 8 days ago |

### Category 2: Rate Limit & Auth Cascades
| Bug | Details |
|-----|---------|
| KilaBz Codex rate limits | Repeated "hit usage limit" errors across 4+ tasks. Reviews silently fail with empty content. |
| Oracle Gemini auth failures | GEMINI_API_KEY not found errors. Recurs when env is lost after restarts. |
| Oracle context poisoning | Went 0-for-10+ on voice reviews, returning stale cached content instead of actual reviews. Fixed with Layer 1 (objective above data fence) but not confirmed resolved. |
| Antman Codex failures | 3 recent failures, falls back to Claude each time. |

### Category 3: Security Scanner False Positives
| Bug | Details |
|-----|---------|
| Legitimate messages quarantined | Competitive analysis message quarantined for "Fake Anthropic system message" because it quoted Claude documentation. The bug audit response itself was also quarantined. |
| Scanner race condition | `[ERROR] File not found` — file moves between scan-start and scan-complete |
| 31 files in dead-letter | Mix of real security tests and false positives. No triage process. |

### Category 4: Silent Task Failures
| Bug | Details |
|-----|---------|
| Dedup guard blocks retries | Once task_id marked `.done`, re-dispatch silently drops. Must append `-v2`, `-v3` manually. |
| Mini-runner missing setsid | `setsid: command not found` — process isolation may be compromised |
| Task timeouts | 5 consecutive timeouts for single task with no output |
| Mack watcher disk space error | `echo: write error: No space left on device` in mack-watcher stderr |

### Category 5: Accumulating Technical Debt
| Bug | Details |
|-----|---------|
| State directory bloat | 91 items in state/, 86 retry count files, multiple temp body files accumulating |
| Disk at 60% capacity | 10GB free on 228GB. /tmp write errors already hit. |
| Scoped permissions v3 gaps | Oracle found 4 unresolved + 4 new critical issues including command injection risk |
| Lobster Bot disappeared from PM2 | Had to manually restart — was completely missing, not just stopped |
| Scrapers removed but may be referenced | LinkedIn/Twitter/Newsletter scrapers deleted, references may remain |

### Category 6: Cross-Instance Contention (recently diagnosed)
| Bug | Details |
|-----|---------|
| Shared inbox notification marker | Single `inbox-notified.marker` shared across all Claude instances. One terminal's hook fires → all others miss messages. 27 messages went unseen for weeks. |
| Autonomous Mack vs Interactive Mack | Two Mack instances (Mini watcher + MacBook interactive) process the same inbox with no coordination. Tasks get processed by the wrong instance. |
| Syncthing sync race | Files can be processed on one machine before they finish syncing to the other |

---

## What We Want From This Review

1. **Are these failures implementation bugs or architectural flaws?** If the architecture is fundamentally sound, we fix the bugs. If the architecture causes these failure modes, we need a structural change.

2. **Is file-based IPC the right choice at our scale?** We have 8 agents, 2 machines, ~30 tasks/day. Is the filesystem sufficient, or should we move to a message queue, database, or API?

3. **How should we handle cross-instance contention?** Multiple consumers (interactive Mack, autonomous Mack, Lobster) reading the same inbox. Per-consumer subdirs? Message queues? Database with row locking?

4. **Is our security model adequate?** Injection scanning with regex, content fencing, scoped permissions, sender auth via YAML frontmatter. What's missing?

5. **How do production multi-agent systems at scale solve these problems?** Compare our approach to Anthropic's internal tools, Google DeepMind, Microsoft AutoGen, CrewAI, or any other multi-agent framework you're aware of.

6. **What would you change first?** Given unlimited engineering time, what's the highest-ROI structural fix?

---

## What NOT to Share Beyond This Review
- No API keys, tokens, or secrets are included in this document
- Agent personality files (SOUL.md) are proprietary
- Specific inbox message contents are not included
- This is an architecture review, not a security penetration test

---

*Prepared April 2026 by Mack (Claude Opus 4.6) for external architecture review.*
