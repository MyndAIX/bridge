# Brief for Perplexity Computer — Full Architecture Map for MyndAIX v2

**Purpose:** Produce the full architecture design for MyndAIX v2 — a **CLI-first multi-agent system orchestrated by Claude Code**, with Perplexity API as the **only external cloud dependency**.

You are not critiquing a design this time. You are designing it.

---

## Context — Where We're Coming From

**Current system (v1, built by accretion over 8 months):**

- Multi-agent coordination via a file-based "bridge" — markdown files in `~/.myndaix/bridge/inbox/<agent>/`, Syncthing-synced across MacBook + Mac Mini.
- Orchestrator is **Lobster**, a Claude Opus instance running inside OpenClaw, accessed via Discord. Lobster receives Discord messages, dispatches work to agents (KilaBz, Oracle, Antman, Recon, Harley, Mini, Mack) by writing markdown files to their inboxes.
- Event sources are scattered: PostToolUse hooks, watchers (launchd), Discord listener, dispatch scripts, auto-router, bridge daemon (`myndaix-daemon.js`). No single control plane.
- Problems this caused: shadow production code never committed; hook posting into operator's Discord channel made it look like LLM was "looping" (it wasn't); enforcement hooks blocked their own dispatches; protocol drift between `dispatch.sh` and `PROTOCOL.md`.

**Tonight's locked decisions (v1.5 → v2 pivot):**

Tonight (2026-04-21) the founder (the user) ran a /boardroom with 3 AI advisors (Claude Opus / GPT / Gemini 2.5 Pro), got an Oracle (Gemini) review, a Perplexity Computer review, and an independent Claude Opus web-chat review. Five reviewers converged on:

1. **Single dispatch authority** — exactly one process mutates task state; everything else is an event source.
2. **Directory state machine + JSONL audit log** (not SQLite). Atomic `rename` for transitions, files stay `ls`/`cat`/`grep`-inspectable.
3. **Node.js implementation** for the control plane (not bash) — structured errors, native JSON, atomic file operations by default.
4. **Per-agent backpressure** — `max_concurrent` + `max_queued` per agent. Daemon must not amplify provider rate-limits into system-wide overload.
5. **Single-writer enforcement** — only the daemon writes to state dirs; automated violation scan.
6. **`audit.jsonl` as write-only forensic history**, not a recovery source. If recovery needed, separate snapshot.
7. **Discord channel separation at protocol** — ops channel (human ↔ orchestrator) vs alerts channel (daemon-authored only).
8. **Per-task `timeout_minutes` frontmatter** — no global timeout.
9. **Manual cold-failover playbook** — no full HA; document the runbook for when Mini dies.
10. **Findings tracker deferred to v2.1** — v1 does task lifecycle only; findings stay in Notion until core is stable.
11. **Lobster migration via "dark launch"** — parallel instance logs outputs for 24h comparison before cutover.
12. **Structured docs** — `docs/daemon/{schemas,adr,runbooks,migration,fixtures}/` not just prose.

---

## The New Vision — CLI-First, Claude-Code-Orchestrated

**Important clarification:** all agents EXCEPT Lobster are already CLI-based on Mini. This includes:
- **KilaBz** — Codex CLI (`codex exec ...`), read-only reviewer
- **Oracle** — Gemini CLI or direct Gemini REST API (`lib/gemini-api.sh`)
- **Antman** — Codex CLI, second-opinion builder
- **Recon** — Claude CLI + Perplexity API for research retrieval
- **Harley** — CLI-based
- **Mini** — Claude CLI, primary pipeline builder (runs on Mini machine)
- **Mack** — Claude Code (me — the CLI the founder is typing into right now, runs on MacBook)
- **Smoke** — CLI pipeline canary. End-to-end smoke tests: can a task enter the system, dispatch, execute, return a result? Low-traffic, idempotent, designated "first to migrate" because its failure doesn't break anything real.

The ONE exception is **Lobster** — Claude Opus running inside OpenClaw, accessed via Discord. Lobster is the orchestrator/dispatcher today. He's the only agent that's not a CLI invocation.

So the shift isn't "move everything to CLI." It's specifically **kill the Discord/OpenClaw orchestration layer and make Claude Code the orchestrator in the terminal**. Founder is typing in Claude Code right now; Claude Code has tool access (Bash, Read, Write, Edit, Agent-for-subagents); Claude Code can dispatch to the already-CLI agents directly. Lobster becomes unnecessary as a separate entity — his role merges into "whoever's running Claude Code" (usually the founder, or a Claude Code instance delegated to run autonomously).

**What this means:**

- **Claude Code** (the Anthropic CLI — `claude` command, tool-using, subagent-capable, persistent session) is the **orchestrator**. Not Lobster-in-Discord.
- **Discord becomes optional / notification-only**, not load-bearing. If we keep it, it's for alerts and quick status pings — not for dispatching work.
- **Agents stay as they are** — CLI invocations from Mini (or MacBook for Mack). Claude Code calls them via `Bash` or spawns them via `Agent` subagents.
- **Perplexity API** is the **only** external cloud dependency the SYSTEM relies on. Anthropic API (Claude), OpenAI API (Codex/GPT), Gemini API are used *by specific agents* as part of their CLI invocation, but the control plane doesn't depend on them — if Codex is down, KilaBz can't review, but the orchestrator keeps working.
- **The bridge inbox/outbox** was load-bearing because Lobster was async and file-based. With Claude Code as orchestrator, much of it may be unnecessary — Claude Code can dispatch and wait synchronously. What survives is: state for long-running tasks, audit log, and cross-machine sync for tasks that hand off between MacBook (Mack) and Mini (Mini, KilaBz, etc.).

**Implication:** this is a radically smaller system than v1. Lobster's 517-line monitor, OpenClaw session management, Discord relay, dispatch queue — all of it is candidate for deletion. The complexity we've been trying to contain via a daemon may in large part disappear because Claude Code IS the orchestrator.

**But:** Claude Code is interactive. It sleeps when the user isn't at the terminal. A system that depends on it orchestrating needs a clear answer to "what runs when the user is asleep?" — e.g., scheduled tasks, long-running builds that span overnight, watchdog monitoring of running agents.

One answer: launchd + CLI scripts for autonomous stuff, Claude Code for interactive orchestration. Another: a thin always-on daemon (the thing we've been designing all night) whose sole job is to run scheduled/autonomous tasks, while Claude Code handles everything interactive. You tell us which is right.

---

## Your Job

Produce the **full architecture map** for MyndAIX v2. Concretely:

### 1. Component inventory
- Every process, script, and service in the proposed system.
- For each: name, role, lifecycle (always-on / on-demand / user-triggered), language, owner, failure signal.

### 2. Data flow diagram (in prose or ASCII)
- How does a task enter the system? (Human types in Claude Code? Cron? External event?)
- How does it flow through orchestration, dispatch, execution, result delivery?
- Where does state live at each stage?

### 3. Agent role rationalization
- Current fleet: Lobster, Mack, Mini, KilaBz, Oracle, Antman, Recon, Harley. Which of these survive in v2? Which merge? Which disappear?
- For each surviving agent: CLI entry point, how Claude Code invokes it, inputs, outputs, where state lives.

### 4. CLI command surface
- What does the operator type? Proposed commands, flags, subcommands.
- Examples: `mx dispatch <agent> <task>`, `mx status`, `mx audit --since 1h`, etc.
- Should be consistent, discoverable, muscle-memory-friendly.

### 5. File and directory layout
- Where does everything live on disk?
- What's synced via Syncthing, what's local-only?
- Where are schemas, configs, state, audit?

### 6. Schemas (core ones)
- Event schema — what a task submission looks like.
- Task schema — full task record with frontmatter fields we've decided (`timeout_minutes`, etc.)
- Audit log entry schema.

### 7. Claude Code's role as orchestrator — concrete
- How does Claude Code dispatch to a subagent vs a CLI process?
- How does it track long-running tasks across terminal sessions?
- What happens when Claude Code isn't running (user asleep)?
- Does it still need a daemon behind the scenes, or does launchd + CLI invocation cover it?

### 8. Perplexity API integration
- What specifically calls Perplexity? (Recon agent only, or others?)
- Rate-limit handling, caching, retries.
- Credential storage (we already have `~/.myndaix/.secrets`).

### 9. Migration path
- From current v1 (Lobster-in-Discord-orchestrated, scattered execution surfaces) to v2 (Claude-Code-orchestrated, CLI-based).
- Phased, with explicit cutover points and rollback per phase.
- Respect the locked decisions above.

### 10. Failure modes + observability
- What's watching the system when the user isn't?
- How do we know the system is healthy?
- Where do alerts land?

---

## Constraints

**Hard constraints:**
- CLI-first. No web UI for operators. Terminal is the interface.
- Perplexity API is the only external cloud dependency the system depends on. Anthropic API (for Claude), OpenAI API (for Codex/GPT), Gemini API are used *by specific agents*, but the system must function without them if the agent isn't needed.
- File inspectability must be preserved. `ls`, `cat`, `grep` are first-class debugging tools.
- Syncthing stays as the cross-machine sync layer (not Dropbox, not S3, not rsync-cron).
- Node.js for anything requiring structured error handling / JSON / async I/O. Bash only for simple glue with strict mode.
- Solo operator. No team to run the system. Complexity budget is tight.

**Soft constraints:**
- Prefer fewer agents over more. If agent X's role can be absorbed into agent Y, propose the merge.
- Prefer CLI invocation over persistent services where feasible. A script that runs and exits is easier to reason about than a daemon.
- Prefer explicit over implicit. Magic behaviors are a known pain point.

**What to push back on if you think the founder is wrong:**
- The Claude-Code-as-orchestrator idea itself. If you think this fundamentally doesn't work (e.g., because the orchestrator needs to run 24/7 and Claude Code sleeps), say so and propose an alternative.
- The Perplexity-as-sole-external idea. If this forces an unnatural architecture, say so.
- Any of tonight's 12 locked decisions if you think they're wrong in the context of this new vision.

---

## Output Format

Deliver as a single markdown document with the 10 sections above. Use tables, ASCII diagrams, and code fences where appropriate. Aim for ~3000-5000 words of substance, not 10k of filler.

End with:
- **Top 3 risks** you see in this architecture.
- **Top 3 open questions** the founder must answer before building.
- **Your confidence level** (high / medium / low) that this architecture will work as designed, with one sentence of reasoning.

Be direct. No hedging. The founder has been burned by consensus-seeking output all night.
