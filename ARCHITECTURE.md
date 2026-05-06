# Architecture

> **Single source of truth for how the multi-agent system works.**
> Every agent should read this on boot. If this doc and another source disagree, this doc wins.

---

## 1. Design philosophy

### Why bash, not a framework

Frameworks (LangChain, CrewAI, AutoGen) give you abstractions that hide what's happening. When something breaks at 3 AM, you're debugging someone else's code path through someone else's data model. CLI tools (`claude`, `gemini`, `codex`) are the opposite: every step is a process you can reproduce in a terminal, every task is a markdown file you can `cat`, every result is a markdown file you can `grep`.

The system is **debuggable by a human with a terminal**. That's the point.

Concrete consequences:
- All agents are bash scripts that source `watchers/lib/common.sh`. No process supervisors, no message brokers, no service mesh.
- All inter-agent messages are markdown files in `inbox/<agent>/`.
- All persistent state is SQLite (`~/.myndaix/memory.db`) plus append-only JSONL (`~/.myndaix/telemetry/tasks.jsonl`).
- All scheduling is `launchd` (LaunchAgents) — the operating system's job runner, not a third-party scheduler.

### Why SQLite, not Postgres / Redis

SQLite is a file. You can `cp` it, `git` it (don't, but you can), `tail -f` its WAL, query it from any language. It runs in-process, so there's no server to manage, no port to forward, no auth to configure. Concurrent reads are free; concurrent writes serialize through the WAL — fine for an 8-agent team.

The throughput ceiling is around 1k writes/sec. We're nowhere near it.

### Why per-agent watchers, not a monolith

Each agent runs in its own process under its own LaunchAgent, so a crash in one watcher doesn't take the others with it. The shared library `watchers/lib/common.sh` carries the cross-cutting code (locking, telemetry, memory queries, pain check). Per-agent scripts hold the agent-specific routing and prompts.

The monolith alternative — one daemon that multiplexes all agents — was tried (`watch-inbox.sh.legacy`, removed in Phase 1.5 of v1.0). It became a single-point-of-failure: when it crashed, nothing ran; when it leaked memory, everything paused.

### Why both file-based inbox and SQLite task queue

The file-based inbox (`inbox/<agent>/<task>.md`) is the human-readable source of truth — you can drop a markdown file in by hand and it gets processed. The SQLite `tasks` table is the same workload represented for atomic claim semantics, retry counts, and dead-letter routing.

They run in parallel as of v1.0. The file inbox is simpler and the SQLite queue is more robust. Both are valid sources of work; watchers check both. Consolidation onto one model is deferred to v2.

### The construction-management metaphor

The system is modeled on residential construction crews:

- **Lobster (GC)** — coordinates specialists, doesn't swing a hammer.
- **Mini, Mack (carpenters)** — execute tasks.
- **Antman (sub)** — second-opinion estimator, called when a job needs cost-tier work.
- **KilaBz (inspector)** — reviews work before it's signed off.
- **Oracle (architect)** — reviews the design before crew breaks ground.
- **Recon (researcher)** — competitive intel, tech research, "what are other teams doing on this?"
- **Harley (designer)** — creative, marketing, copy.
- **Smoke (final inspector)** — automated QA on the finished work.

Work is reviewed before it ships. The team learns from every job. This pattern works for AI agents.

---

## 2. Three orchestration tiers

The system is a stack. Each tier is a complete stopping point — adopt the next when ready.

### Level 1 — CLI dispatch

```
user shell                              filesystem                      watcher
──────────                              ──────────                      ───────
$ scripts/dispatch.sh             ┌──►  inbox/mini/                ──►  mini-watcher.sh
    --to mini --from cli          │       <ts>-cli-task-<slug>.md       (LaunchAgent fires
    --subject "say hello"         │                                      on file event)
    --objective "..."             │                                              │
    --priority P3                 │                                              ▼
    --scope-in "/tmp"             │                                     mini-runner.sh
    --done "..."                  │                                     (Claude/Codex)
    --body "echo hello"           │                                              │
                                  │                                              ▼
                                  │                                     processed/<task>.md
                                  │                                              +
                                  │                                     inbox/lobster/<result>.md
                                  │                                              │
                                  │                                              ▼
                                  └────────  user reads result manually
```

No Discord. No OpenClaw. No daemon required for the dispatch itself (only the watcher's LaunchAgent, which is OS-managed).

### Level 2 — OpenClaw + Discord

```
Discord #command-center  ──slash command──►  OpenClaw gateway
                                                      │
                                                      ▼
                                            inbox/dispatch/<msg>.md
                                                      │
                                          (auto-router.sh routes to agent)
                                                      ▼
                                            inbox/<agent>/<task>.md
                                                      │
                                                      ▼
                                            <agent>-watcher.sh
                                                      │
                                                      ▼
                                            inbox/lobster/<result>.md
                                                      │
                                          (lobster-notifier PM2 tails)
                                                      ▼
                                          Discord #command-center
```

OpenClaw lives in a sibling repo (not bundled here). The interface is just markdown files in `inbox/dispatch/` — write your own translator if you want to integrate Slack, Telegram, email, etc.

### Level 3 — Factory pipeline

```
factory/specs/SPEC-X.md          ──►  Oracle review (architecture + security)
                                                │
                                                ▼
                                  scripts/dispatch.sh --to mini --type task ...
                                                │
                                                ▼
                                  Mini implements (watchers/mini-runner.sh)
                                                │
                                                ▼
                                  scripts/dispatch.sh --to kilabz --type review
                                                │
                                                ▼
                                  KilaBz reviews → eval scorecard
                                                │
                                                ▼
                                  Oracle architecture sign-off
                                                │
                                                ▼
                                  ship + write to factory/knowledge/
```

The full choreography lives in `factory/workflows/<project>.md`. Lobster reads the workflow id from the spec's frontmatter and dispatches the next stage automatically when an inbox result matches a transition.

---

## 3. System topology

```
┌─── Mac Mini (always-on host) ────────────────────────────────────────────┐
│                                                                          │
│  ~/.myndaix/                                                             │
│   ├── memory.db (SQLite)        ─── Upgrade 3, 5, 6                      │
│   ├── telemetry/tasks.jsonl     ─── Upgrade 1                            │
│   └── bridge/                                                            │
│       ├── inbox/                ◄── dispatch entry point                 │
│       │   ├── dispatch/         ◄── OpenClaw/Discord drops here          │
│       │   ├── mini/, mack/, antman/, kilabz/, oracle/, recon/,           │
│       │   ├── harley/, smoke/, lobster/                                  │
│       │   └── quarantine/       ─── auto-managed bad-frontmatter         │
│       ├── processed/            ─── archived completed tasks             │
│       ├── state/                ─── runtime: heartbeats, daily-runs,     │
│       │                              dedupe, paused flags, checkpoints  │
│       ├── locks/                ─── atomic mkdir locks per watcher       │
│       ├── queue/                ─── SQLite-backed queue spillover        │
│       ├── dead-letter/          ─── tasks that failed past retry budget  │
│       │                                                                  │
│       ├── watchers/                                                      │
│       │   ├── lib/common.sh     ─── shared: log, lock, telemetry,        │
│       │   │                          memory, pain, pattern, validate    │
│       │   ├── lib/parallel.sh   ─── SQLite atomic claim                  │
│       │   ├── lib/knowledge.sh  ─── memory.db query/save                 │
│       │   ├── lib/self-healing.sh ─── failure classification + retry    │
│       │   ├── mini-watcher.sh + mini-runner.sh                           │
│       │   ├── mack-watcher.sh + mack-runner.sh                           │
│       │   └── {antman,kilabz,oracle,recon,harley,smoke}-watcher.sh       │
│       │                                                                  │
│       ├── scripts/                                                       │
│       │   ├── dispatch.sh       ─── Tier-1 entry, schema-enforced        │
│       │   ├── auto-router.sh    ─── inbox/dispatch → inbox/<agent>       │
│       │   ├── smart-router.sh   ─── per-task model selection             │
│       │   ├── dashboard.sh      ─── SQLite-backed status board           │
│       │   └── ...                                                        │
│       │                                                                  │
│       ├── hooks/                                                         │
│       │   ├── branch-guard.sh   ─── PreToolUse: block git push to main   │
│       │   ├── destructive-blocker.sh ─── PreToolUse: block rm -rf, etc.  │
│       │   ├── syntax-check.sh   ─── PreToolUse: bash -n before exec      │
│       │   └── pre-dispatch-gate.sh ─── PreToolUse: keyword scan          │
│       │                                                                  │
│       ├── factory/              ─── spec-driven build loop (Tier 3)      │
│       └── launchd/templates/    ─── LaunchAgent .plist templates         │
│                                                                          │
│  Processes:                                                              │
│   ├── PM2: myndaix-daemon       ─── MCP bridge server                    │
│   ├── PM2: lobster-notifier     ─── tails inbox/lobster, posts Discord   │
│   └── launchd: ~24 ai.myndaix.* + com.myndaix.* LaunchAgents             │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

         (Optional) Syncthing replicates ~/.myndaix/bridge/ to peer machine

┌─── MacBook (peer, optional) ─────────────────────────────────────────────┐
│  ~/.myndaix/bridge/  ◄── synced read-write                               │
│  Runs only mack-watcher.sh on this side                                  │
└──────────────────────────────────────────────────────────────────────────┘
```

The watcher pattern: a LaunchAgent (`ai.myndaix.<agent>-watcher`) registers `WatchPaths` on `inbox/<agent>/`. When `fswatch` detects a new `.md`, launchd fires the watcher script. The watcher acquires a lock (atomic `mkdir`), validates the frontmatter, runs the runner (or inline logic), writes a result to `inbox/lobster/`, and archives the task to `processed/`.

---

## 4. OpenClaw & Lobster (Tier 2 detail)

OpenClaw is the **inbound gateway** — a separate sibling project that receives Discord messages and translates them into bridge dispatches. It does not orchestrate; it just translates.

The translation:

```
@lobster please review SPEC-AUTH on branch feature/auth
   │
   ▼
inbox/dispatch/<ts>-discord-message-<slug>.md
   {
     ---
     from: discord:<userid>
     to: lobster
     type: message
     subject: please review SPEC-AUTH on branch feature/auth
     ---
     please review SPEC-AUTH on branch feature/auth
   }
```

Lobster (running as an interactive Claude Code session, not a watcher) acts as the **orchestrator**:
- Reads `inbox/dispatch/` and `inbox/lobster/`
- Decides which agent should handle each item
- Dispatches via `scripts/dispatch.sh --to <agent> ...`
- When results land in `inbox/lobster/`, summarizes for the human

`lobster-notifier` is a PM2-managed Node script (sibling repo) that tails `inbox/lobster/` and posts results back to Discord via webhook. It's the only "always-on" Lobster-related process; the interactive Lobster session itself runs only when you have Claude Code open.

`auto-router.sh` is the simple case: messages dropped in `inbox/dispatch/` with explicit `to: <agent>` get moved to `inbox/<agent>/` directly, bypassing Lobster. This handles structured automation; Lobster handles natural-language routing.

---

## 5. Agent architecture

Each agent has a watcher script in `watchers/`. Most are inline (the watcher contains the agent's full logic). Mini and Mack are an exception — they have separate `*-runner.sh` files because their runner work is large enough that splitting reduces watcher complexity.

```
watchers/
├── lib/common.sh           ─── sourced by every watcher
├── mini-watcher.sh         ─── claim, validate, dispatch to runner
├── mini-runner.sh          ─── compose prompt, invoke claude, write result
├── mack-watcher.sh         ─── (same pattern as mini)
├── mack-runner.sh
├── antman-watcher.sh       ─── inline (Codex first, Claude fallback)
├── kilabz-watcher.sh       ─── inline (Codex first, Gemini fallback)
├── oracle-watcher.sh       ─── inline (Gemini CLI via OAuth)
├── recon-watcher.sh        ─── inline (Perplexity API → Claude)
├── harley-watcher.sh       ─── inline (Claude only)
├── smoke-watcher.sh + smoke-runner.sh  ─── inline + runner
├── inbox-watcher.sh        ─── monitors inbox/lobster/, sends Discord ping
└── lobster-discord-relay.sh ─── relays Lobster events to Discord
```

### Engine selection

`scripts/smart-router.sh` chooses model based on task complexity:
- Trivial tasks (<2KB body, low priority) → Claude Haiku (fast + cheap)
- Standard tasks → Claude Sonnet
- Complex tasks (high priority, large body, review) → Claude Opus

Per-agent overrides:
- **Antman, KilaBz** — Codex first, fall back to Claude/Gemini if Codex auth expires.
- **Oracle** — Gemini 2.5 Pro CLI exclusively (uses OAuth, not API key).
- **Recon** — Perplexity Sonar-Pro for research, Claude for synthesis.
- **Harley** — Claude only (no second engine).

### Codex-first vs Claude-first

Antman and KilaBz are intentionally Codex-first because Codex is significantly cheaper for routine code generation and review. Mini and Mack are Claude-first because they're the primary builders and Claude's reasoning is worth the cost premium for greenfield code.

This split also gives the system a built-in **second opinion**: if Mini and Antman disagree on an approach, the disagreement surfaces and the user (or Lobster) breaks the tie.

### The Mack inline-functions exception

Mack-runner.sh has ~25 inline copies of `common.sh` functions instead of `source`-ing the library. This is intentional: Mack runs on the peer machine over Syncthing, and a stale `common.sh` would silently corrupt Mack's runtime. Inline copies are versioned with the runner and update atomically.

---

## 6. The upgrade stack

Six numbered upgrades + Symphony Part A. Each addresses one structural deficiency in the v0 system.

| # | Upgrade | Problem solved | Key functions in `lib/common.sh` |
|---|---|---|---|
| 1 | **Telemetry** | No visibility into what agents were doing | `log_task` |
| 2 | **Schema + Pain** | Bad frontmatter silently failed; repeated failures didn't escalate | `validate_task`, `check_pain` |
| 3 | **Memory** | Agents had no persistent knowledge between sessions | `query_memory`, `save_memory` |
| 4 | **Self-healing** | Failures had no recovery strategy | `classify_failure`, `retry_with_budget` |
| 5 | **Task queue** | File-based inbox lost atomic-claim semantics under concurrent watchers | SQLite `tasks` table + `parallel.sh::claim_task_parallel` |
| 6 | **Pattern detection** | Repeated successes didn't promote into rules | `pattern_record`, auto-promote at occurrences ≥ 3 |
| A | **Symphony Part A** | Dispatch lacked workflow context | Inject `### Build agents` etc. sections at dispatch time |

Each upgrade is wired into per-agent watchers via `lib/common.sh` calls. The configuration knobs (e.g. pain threshold, retry budget) are exposed as env vars at the top of `common.sh`.

---

## 7. Safety & guardrails

Layered defense, fail-closed at every step.

### Hook system (Claude Code `PreToolUse`)

Three hooks gate every Bash invocation by `claude`:

- **`branch-guard.sh`** — regex match on `git push.*origin (main|master)` (incl. `--force`, `--force-with-lease`). Blocks. Humans can bypass with `--no-verify` if they really need to; agents never can because they don't know the flag exists.
- **`destructive-blocker.sh`** — blocks `rm -rf /`, `rm -rf $HOME`, `DROP TABLE`, `git reset --hard origin`, `git clean -fdx`, `git filter-branch`. Pattern list in the script.
- **`syntax-check.sh`** — runs `bash -n` on `bash -c` payloads before exec. Rejects on parse error. Catches syntactically broken bash before it does damage.

Registered via `.claude/settings.json` (project-local, with `${CLAUDE_PROJECT_DIR}`) and/or `~/.claude/settings.json` (user-global, via `scripts/install-claude-hooks.sh`). User-global takes precedence; pick one.

### `pre-dispatch-gate.sh`

Different role, also a `PreToolUse` hook. Scans dispatch and SCP commands for keywords (e.g. `prod`, `production`, `--force`) and blocks if the destination matches `${ALLOWED_TARGETS}` patterns. Configured via `~/.myndaix/.secrets`.

### Per-agent sender allowlists

Every agent's watcher (or `scripts/validate-task.sh` on its behalf) checks the `from:` frontmatter against an allowlist:

```
lobster mack mini antman kilabz oracle recon harley jefe cli
```

`cli` is the v1.0 OSS addition for human-typed Tier-1 dispatches. `jefe` is the system role for the human user. Sender not on the list → task quarantined.

### Circuit breaker

`check_pain` tracks rolling failure counts per agent (default: 5 failures in 30 min triggers pause). When tripped, the watcher writes `state/<agent>-paused` and stops claiming new tasks. The user resets via `rm state/<agent>-paused` after fixing root cause.

Reviewers (KilaBz, Oracle) have a separate pain-vs-verdict counter: a "rejection" verdict is not a "failure" — it's a successful review with a negative outcome. Conflating the two would pause reviewers every time they correctly rejected something.

### Task size cap, tier check, dedupe

- 50 KB body limit. Larger → quarantined. Forces tasks to reference external files instead of inlining novels.
- `tier: auto` required for autonomous processing. Tasks without it sit in `inbox/<agent>/` indefinitely until a human moves them.
- Dedupe guard: `state/dedupe/<task_id>.done` markers. Append `-v2` to retry. Prevents infinite loops on watcher restart.

---

## 8. Factory scaffold

Factory is the spec-driven build loop. Layout:

```
factory/
├── README.md
├── workflows/<project>.md     agent choreography per project
├── specs/<id>.md              what to build
├── scenarios/<id>.md          how it should behave
├── evals/<id>.md              acceptance criteria + scorecard
├── knowledge/
│   ├── patterns/              auto-promoted via Upgrade 6
│   ├── runbooks/              how-to-recover docs
│   └── postmortems/           what went wrong
└── dashboards/                rendered status (typically auto-generated)
```

Frontmatter conventions documented in `factory/README.md`. The minimum every file needs: `id`, `title`, `status`, `owner`, `created`, `updated`. Agents reference factory items by `id`, never by path.

The weekly auto-audit (`ai.myndaix.weekly-audit` LaunchAgent, opt-in) dispatches Recon Sundays to scan `factory/specs/` for stale items and post a digest.

---

## 9. The OACL framework

Observe → Frame → Select → Execute → Validate → Reinforce → Upgrade.

| Step | Implementation |
|---|---|
| **Observe** | Telemetry (Upgrade 1) — `log_task` writes append-only events to `~/.myndaix/telemetry/tasks.jsonl` |
| **Frame** | Schema validation (Upgrade 2) — `scripts/validate-task.sh` + `validate_task` lib |
| **Select** | Smart router (`scripts/smart-router.sh`) + auto-router (`scripts/auto-router.sh`) |
| **Execute** | Per-agent watcher → runner |
| **Validate** | Pain check (Upgrade 2) — `check_pain` rolling failure count |
| **Reinforce** | Memory (Upgrade 3) — confidence decay in `memory.db`, used entries strengthen, unused decay |
| **Upgrade** | Pattern detection (Upgrade 6) — auto-promote at occurrences ≥ 3 |

**No reinforcement without validation. No memory without proof. No automation without repeated success.** This isn't a catchy acronym — it's the actual control flow. The 6 upgrades each implement one layer; missing any layer means the system can't learn safely.

A concrete example: Mini builds a feature successfully (Execute). Telemetry logs the task (Observe). Schema validation passes (Frame). Pain count stays at zero (Validate). The fact "Mini handles auth-flow specs reliably" gets recorded in `memory.db` with confidence 1.0 (Reinforce). After three identical successes, the pattern auto-promotes to a routing rule: "auth specs → Mini, not Antman" (Upgrade).

---

## 10. How to add a new agent

1. **Create a watcher**: copy `watchers/mini-watcher.sh` to `watchers/<newagent>-watcher.sh`. Replace `AGENT_NAME=mini` with your name.
2. **Create the inbox**: `mkdir inbox/<newagent>/`.
3. **LaunchAgent template**: copy `launchd/templates/ai.myndaix.mini-watcher.plist.template` to `launchd/templates/ai.myndaix.<newagent>-watcher.plist.template`. Update the `Label`, `ProgramArguments`, and `WatchPaths`.
4. **Sender allowlist**: add `<newagent>` to all six allowlist sites:
   - `scripts/dispatch.sh:VALID_AGENTS`
   - `scripts/auto-router.sh:VALID_AGENTS`
   - `scripts/validate-task.sh:VALID_AGENTS`
   - `scripts/scan-inbound.sh:TRUSTED_SENDERS`
   - `scripts/oracle-watcher.sh:allowed_agents` (×2)
   - `watchers/lib/chaining.sh:VALID_AGENTS`
5. **Manifest registration**: add the agent to `SYSTEM-MANIFEST.md` § 2 (Agent Roster).
6. **Wire upgrades**: confirm the watcher sources `lib/common.sh` (it does by default — telemetry, pain, memory, pattern detection wired automatically).
7. **Reinstall LaunchAgents**: `bash scripts/install-launch-agents.sh` then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.myndaix.<newagent>-watcher.plist`.
8. **Test**: `./scripts/dispatch.sh --to <newagent> --from cli --subject "smoke" --objective "test new agent" --priority P3 --scope-in /tmp --done "result emitted" --body "say hi"`.

---

## 11. How to add a new upgrade

1. **Add the function** to `watchers/lib/common.sh` (or a new lib file). Document inputs/outputs and side effects in a header comment.
2. **Wire into watchers**: call the new function from each watcher (or just the relevant ones — not every upgrade applies everywhere).
3. **Add telemetry**: emit a `log_task` event with the new event type so the upgrade's behavior shows up in `tasks.jsonl`.
4. **Sandbox-test**: dispatch a task with `tier: manual` (not `auto`) and trace the new behavior end-to-end before flipping to autonomous.
5. **Document in SYSTEM-MANIFEST.md** § 4 (Upgrade Stack), with the problem solved and key functions.
6. **Map to OACL** — which step does the upgrade belong to? Each upgrade should clearly belong to exactly one OACL step. If it doesn't, it's probably two upgrades.
