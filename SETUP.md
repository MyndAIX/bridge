# Setup

Install MyndAIX Bridge in three tiers. Each tier is a complete stopping point — pick the level of automation you want and stop there.

| Tier | Capability | Time to first task |
|---|---|---|
| **1 — CLI dispatch** | Type a terminal command; agent picks it up; result lands in `inbox/lobster/`. | 5 min |
| **2 — OpenClaw + Discord** | Lobster receives commands via Discord; routes to agents; relays results back. | + 30 min |
| **3 — Factory pipeline** | Spec-driven autonomous build loop: spec → review → build → review. | + 1 hr (and you write specs) |

Tier 1 is mandatory for the others. Skip ahead only after Tier 1 is verified working.

---

## Prerequisites

- macOS 13+ (Ventura) or Linux. Tested on macOS 14 (Sonoma) and 15 (Sequoia / 26.2).
- [Homebrew](https://brew.sh) on macOS.
- Node.js ≥ 20.
- `sqlite3` ≥ 3.35 (`brew install sqlite`).
- `jq` (`brew install jq`).
- `openssl` (preinstalled on macOS).
- **Required for safety hooks**: [Claude Code](https://claude.ai/download) installed and authenticated (`claude auth`).
- Optional: Tailscale for two-machine setups, Syncthing for cross-machine sync of `~/.myndaix/bridge/`.

---

## Tier 1 — CLI dispatch (everyone)

### 1. Clone

```bash
git clone https://github.com/MyndAIX/myndaix-bridge-oss ~/.myndaix/bridge
cd ~/.myndaix/bridge
npm install
```

### 2. Secrets

```bash
cp .secrets.example ~/.myndaix/.secrets
chmod 600 ~/.myndaix/.secrets
$EDITOR ~/.myndaix/.secrets
```

Add at minimum:
- `PERPLEXITY_API_KEY` (if you want Recon)
- `GEMINI_API_KEY` (if you want KilaBz Gemini fallback; Oracle uses OAuth)
- Leave Discord webhooks empty for Tier 1 — watchers fail-closed when unset.

### 3. Memory database

```bash
mkdir -p ~/.myndaix
sqlite3 ~/.myndaix/memory.db < schema.sql
sqlite3 ~/.myndaix/memory.db ".tables"   # expect: memory, patterns, tasks, migration_log
```

### 4. Register safety hooks  ⚠️ **CRITICAL — DO NOT SKIP**

Without this, agents that invoke `claude` from arbitrary working dirs (e.g. inside per-task git worktrees) run with no safety rails — they could `git push --force` to main, `rm -rf` your repo, or execute syntactically broken bash.

```bash
bash scripts/install-claude-hooks.sh
```

This script merges three `PreToolUse` hooks into `~/.claude/settings.json`, all matching the `Bash` tool. The exact JSON it writes:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/abs/path/to/bridge/hooks/branch-guard.sh" },
          { "type": "command", "command": "/abs/path/to/bridge/hooks/destructive-blocker.sh" },
          { "type": "command", "command": "/abs/path/to/bridge/hooks/syntax-check.sh" }
        ]
      }
    ]
  }
}
```

What each hook gates:

| Hook | Blocks |
|---|---|
| `branch-guard.sh` | `git push origin main\|master` (incl. `--force`, `--force-with-lease`) |
| `destructive-blocker.sh` | `rm -rf /`, `rm -rf $HOME`, `DROP TABLE`, `git reset --hard origin`, `git clean -fdx`, `git filter-branch` |
| `syntax-check.sh` | `bash -n` on `bash -c` payloads — rejects on parse error before exec |

The installer expands `$BRIDGE_DIR` to absolute paths at install time. (Claude Code does NOT expand env vars in `command` strings within user-global `settings.json`.)

**Verify:**

```bash
jq '[.hooks.PreToolUse[]?|select(.matcher=="Bash")|.hooks[]] | length' ~/.claude/settings.json
# expect: 3

# Negative test (must be blocked):
claude --dangerously-skip-permissions --print 'run: rm -rf $HOME/test-target' 2>&1 | grep -q 'destructive\|blocked' && echo "✓ destructive-blocker active"
```

**Project-local alternative.** This repo also ships `.claude/settings.json` (project-local) with the same hooks scoped via `${CLAUDE_PROJECT_DIR}` — active automatically when running `claude` from inside the bridge dir. Use the user-global form (the installer above) when watchers spawn `claude` from worktrees outside the bridge dir. User-global takes precedence; pick one.

### 5. Install LaunchAgents

```bash
bash scripts/install-launch-agents.sh
```

This script reads templates from `launchd/templates/*.template`, substitutes `__BRIDGE_DIR__` / `__HOME__` / `__USER__` placeholders with absolute paths, and writes the result to `~/Library/LaunchAgents/`. Each generated plist is validated with `plutil -lint` before install.

```bash
# Bootstrap (loads + starts)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.myndaix.*.plist

# Verify watchers are loaded
launchctl list | grep ai.myndaix
```

### 6. Start the daemon (PM2)

```bash
pm2 start ecosystem.config.js
pm2 save
pm2 list   # myndaix-daemon should be 'online'
```

The daemon mediates inbox/outbox events for all per-agent watchers. PM2 owns it; if you have a competing `ai.myndaix.daemon` LaunchAgent from an older install, disable it (`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.myndaix.daemon.plist`).

### 7. Dispatch your first task

```bash
./scripts/dispatch.sh \
  --to mini --from cli \
  --subject "say hello" \
  --objective "echo a friendly message" \
  --priority P3 --scope-in "/tmp" --done "Output is non-empty" \
  --body "echo hello from mini"
```

Watch the result land:

```bash
tail -f ~/.myndaix/bridge/inbox/lobster/*.md
```

Within ~10s you should see Mini's result file appear. If it doesn't:

```bash
tail -50 ~/.myndaix/bridge/watchers/mini-watcher.log
```

✓ If you see a result, **Tier 1 is done**.

---

## Tier 2 — OpenClaw + Discord (optional)

This adds Discord-based orchestration: type `@lobster …` in `#command-center` and Lobster routes the dispatch to the right agent, then relays the result back. Requires a Discord bot, a webhook, and the OpenClaw gateway service.

### 8. What OpenClaw is

OpenClaw is a sibling project (separate repo) that translates Discord slash-commands and DMs into bridge dispatches:

```
Discord #command-center  ──slash command──►  OpenClaw gateway
                                                    │
                                                    ▼
                                          $BRIDGE_DIR/inbox/dispatch/
                                                    │
                                       (auto-router.sh routes to agent inbox)
                                                    ▼
                                          inbox/<agent>/  → watcher claims
                                                    │
                                                    ▼
                                          inbox/lobster/<result>.md
                                                    │
                              (lobster-notifier PM2 process posts via webhook)
                                                    ▼
                                          Discord #command-center
```

OpenClaw is not bundled with this repo. Source: `<user-supplied URL>` (or write your own translator — the dispatch interface is just markdown files in `inbox/dispatch/`).

### 9. Discord bot setup

1. Create an application at <https://discord.com/developers/applications>.
2. Generate a bot token. Copy it.
3. Invite the bot to your server with the `bot` and `applications.commands` scopes.
4. Create a `#command-center` channel.
5. Generate a webhook URL for `#command-center` → copy it.

### 10. OpenClaw configuration

Install OpenClaw per its README. Configure:

- Inbox path → `~/.myndaix/bridge/inbox/dispatch/`
- Discord bot token → `~/.openclaw/.env` as `DISCORD_BOT_TOKEN=…`

### 11. Webhook in secrets

Add to `~/.myndaix/.secrets`:

```bash
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/<id>/<token>"
```

Re-`source` it (or restart watchers) so `inbox-watcher.sh` picks it up.

### 12. Lobster-notifier (PM2)

The notifier is an external sibling repo (`~/.myndaix/lobster-bot/notifier.js`) that tails `inbox/lobster/` and posts results back via webhook. Install per its README, then:

```bash
cd ~/.myndaix/lobster-bot && pm2 start notifier.js && pm2 save
```

### 13. Verify Tier 2

In `#command-center`, post `@lobster status`. Lobster should respond with a system summary within ~10s.

---

## Tier 3 — Factory pipeline (advanced)

Spec-driven autonomous build loop. Use this when a single task balloons into a week of agent-hours and you want one place to track it.

### 14. Factory layout

```
factory/
├── specs/         what to build
├── scenarios/     how it should behave
├── evals/         acceptance criteria + scorecard
├── workflows/     agent choreography per project
└── knowledge/     patterns, runbooks, postmortems (auto-promoted)
```

See `factory/README.md` for the full framework and `factory/specs/example-spec.md` / `factory/workflows/example-workflow.md` for templates.

### 15. Write a spec

```bash
cp factory/specs/example-spec.md factory/specs/SPEC-MY-FEATURE.md
$EDITOR factory/specs/SPEC-MY-FEATURE.md
```

Fill in: id, title, what, why, in scope, out of scope, acceptance criteria, open questions.

### 16. Dispatch through the pipeline

```bash
./scripts/dispatch.sh \
  --to oracle --from cli --type review \
  --branch main \
  --subject "review SPEC-MY-FEATURE" \
  --objective "approve or list blockers" \
  --body "$(cat factory/specs/SPEC-MY-FEATURE.md)"
```

On approval, Oracle's result triggers Lobster to dispatch to Mini for build, then to KilaBz for review, then back to Oracle for architecture sign-off. The full chain is defined in `factory/workflows/example-workflow.md`.

### 17. Weekly auto-audit

The `ai.myndaix.weekly-audit` LaunchAgent (registered Sundays via `launchd/templates/`) dispatches Recon to scan `factory/specs/` for stale items (status: active, no update in 14 days) and post a digest to Lobster. Opt-in — load the plist when ready:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.myndaix.weekly-audit.plist
```

---

## Operations

### Daily

```bash
# Health check
bash scripts/dashboard.sh

# Live logs
tail -f ~/.myndaix/bridge/logs/daemon.log

# Watcher logs (per agent)
tail -f ~/.myndaix/bridge/watchers/mini-watcher.log
```

### Weekly

```bash
# Memory decay (autonomous via ai.myndaix.memory-decay LaunchAgent)
sqlite3 ~/.myndaix/memory.db "SELECT domain, COUNT(*) FROM memory WHERE deprecated=0 GROUP BY domain;"

# Dead-letter triage
ls ~/.myndaix/bridge/dead-letter/   # tasks the system gave up on
```

### When something breaks

```bash
# Pause a noisy agent
touch ~/.myndaix/bridge/state/mini-paused

# Reset its pain counter (after fixing root cause)
rm ~/.myndaix/bridge/state/mini-pain.json

# Force re-dispatch of a stuck task
mv ~/.myndaix/bridge/queue/running/<id>.md ~/.myndaix/bridge/inbox/<agent>/
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "DISCORD_WEBHOOK not set; skipping notification" | Tier 1 default — no Discord configured | Ignore (Tier 1 doesn't need Discord) or set `DISCORD_WEBHOOK` in `.secrets` |
| Watcher doesn't pick up a task | `launchctl list \| grep ai.myndaix` shows no PID | Re-bootstrap; check `WatchPaths` in the installed plist points to `inbox/<agent>` |
| `BRIDGE_DIR not set` errors | First-run before secrets sourced | Open a fresh terminal so `~/.myndaix/.secrets` re-sources, or `export BRIDGE_DIR="$HOME/.myndaix/bridge"` |
| Hook fires on every command and slows the shell | hooks intentionally check every Bash invocation | Acceptable; hooks return immediately for safe commands |
| `claude --print` hangs | Auth expired | `claude auth` to refresh |
| `gemini` fails for Oracle | OAuth expired | `gemini auth login` (Sign in with Google) |
| `pm2 list` shows myndaix-daemon offline + restarting | Conflicting LaunchAgent | `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.myndaix.daemon.plist` then restart PM2 |
| `dispatch.sh` rejects valid agent | Allowlist out of date | Check `scripts/dispatch.sh:VALID_AGENTS` includes the agent name |
| Hook not firing on Bash | settings.json malformed | `jq -e . ~/.claude/settings.json`; restore from `~/.claude/settings.json.bak.*` |

When in doubt, check three places: the watcher log (`~/.myndaix/bridge/watchers/<agent>-watcher.log`), the daemon log (`~/.myndaix/bridge/logs/daemon.log`), and the dashboard (`bash scripts/dashboard.sh`).
