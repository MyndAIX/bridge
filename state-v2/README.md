# state-v2/ — Control-Plane Daemon State

This directory is the authoritative state for the MyndAIX control-plane daemon. It is **Mini's truth.** MacBook reads via Syncthing; only the daemon (running on Mini) mutates these paths.

## Invariants

1. **Only the daemon writes here.** Any other process writing to `events/processed/`, `tasks/*/`, or `findings/*/` is a protocol violation and should be alarmed by the daemon.
2. **All mutations are atomic renames.** No partial writes, no in-place edits. Syncthing-safe.
3. **`audit.jsonl` is append-only.** One line per state transition. Survives restarts.

## Directory Purposes

| Path | Who writes | Contents |
|------|-----------|----------|
| `events/incoming/` | Event sources (hooks, watchers, Discord listener, CLI) | New events, not yet claimed. Daemon claims by `rename` to `processed/`. |
| `events/processed/` | Daemon only | Claimed events, kept for audit. |
| `events/malformed/` | Daemon only | Events that failed parse. Operator triage required. |
| `tasks/pending/` | Daemon only | Events promoted to tasks, waiting for worker slot. |
| `tasks/active/<agent>/` | Daemon writes, agent reads | Dispatched work. Agents pull from their own subdir. |
| `tasks/done/<agent>/` | Agent writes (via daemon-supervised move) | Completed tasks. |
| `tasks/failed/<agent>/` | Agent writes (via daemon-supervised move) | Failed tasks. Requires triage. |
| `findings/open/` | Daemon (from reviewer outputs) | Reviewer findings not yet addressed. |
| `findings/fixed/` | Daemon (on commit-message match) | Findings referenced by a commit's `Fixes:` trailer. |
| `findings/wontfix/` | Daemon (on operator event) | Operator-decided-to-skip findings. |

## File Naming

- Events: `{YYYYMMDDHHMMSS}-{source}-{8char}.md` (e.g., `20260421224503-discord-a3f1b2c4.md`)
- Tasks: same id as source event (1:1 mapping; a single event becomes at most one task)
- Findings: `{sha256-of-finding-text}.md` (content-addressed, dedupes identical findings)

## See also

- `docs/DESIGN-control-plane-daemon.md` — authoritative design
- `state-v2/audit.jsonl` — ground truth for "what happened when" (created by daemon on first start)
- `state-v2/daemon.pid/` — singleton lock (atomic mkdir directory, not a file)
