# DESIGN — Lobster Loop Auto-Wipe

**Status:** READY FOR ORACLE REVIEW — Jefe approved parameters 2026-04-21
**Author:** Mack
**Date:** 2026-04-21
**Problem:** Lobster repeats identical Discord responses. Manual session wipe works but requires Jefe to notice and ask.

---

## What It Does

A behavioral watchdog that detects when Lobster has emitted the same Discord response twice consecutively (loop signature) and automatically runs the session-wipe emergency fix before Jefe has to intervene.

## Why

- `lobster-monitor.sh` already exists and rotates on *resource* signals (RSS, CPU, uptime, session size). It does not detect behavioral loops.
- The loop bug has recurred at least 4 times despite fixes (duplicate daemon, bot.js, voice context, bloated session). Root cause is not single — detection at the symptom layer catches all of them.
- Manual wipe is reliable but depends on Jefe noticing. Missed loops waste his time and erode trust in Lobster.

## Data Flow

```
OpenClaw session jsonl (append-only)
        │
        ▼
[loop-detector.sh]  — runs every 60s via LaunchAgent
        │  reads last N assistant messages from active jsonl
        │  hashes each, compares
        ▼
  identical twice in a row?
        │
        ├── no → exit 0 (log heartbeat)
        │
        └── yes → acquire claim lock (atomic mkdir)
                 │
                 ▼
         [wipe-session.sh] — same logic as emergency fix
                 │  - set sessionId=null, systemSent=false in sessions.json
                 │  - rename active jsonl to .reset.loop-<ts>
                 │  - openclaw gateway restart
                 │
                 ▼
         append event to state/loop-events.jsonl
                 │
                 ▼
         post Discord alert via webhook ("auto-wiped: loop detected at <ts>")
```

## Inputs

- **Active session jsonl:** `~/.openclaw/agents/main/sessions/<uuid>.jsonl` (discovered via `sessions.json` lookup by channel key)
- **Channel key:** `agent:main:discord:channel:1483696525040291894`
- **History window:** last 2 assistant messages (tunable; default 2)

## Outputs

- **Side effects:** sessions.json mutation, jsonl rename, gateway restart
- **State:** `state/loop-events.jsonl` — append-only record `{ts, sha256_of_response, window_size, wiped: true}`
- **Alert:** Discord webhook message (non-blocking, 5s timeout)

## Detection Algorithm

1. Read sessions.json → get active `sessionId` for channel key.
2. Find active jsonl: `sessions/<sessionId>.jsonl` (exists, not a `.reset.*`).
3. Parse jsonl line-by-line, filter to `role == "assistant"` entries with non-empty content.
4. Take last 2 messages, normalize (trim whitespace, lowercase), SHA-256 each.
5. If hashes equal AND both hashes differ from the last-wiped hash (anti-double-fire) → trigger wipe.

## Edge Cases

| Case | Handling |
|------|----------|
| No active session | exit 0 (nothing to check) |
| jsonl missing | exit 0 with warning log |
| < 2 assistant messages | exit 0 (not enough signal) |
| Legitimate repeat (Jefe asks same question twice, Lobster correctly answers same) | Cooldown: don't re-wipe within 600s of last wipe (matches lobster-monitor.sh cooldown). Also: only fire if Lobster replied to *different* inbound messages. |
| Concurrent runs | Atomic mkdir lock at `/tmp/lobster-loop-detector.lock`, stale after 300s |
| Malformed jsonl line | skip line, continue parsing |
| Gateway restart fails | log + alert, do NOT retry (manual intervention) |
| Webhook down | non-blocking, just log |

## Security Surface

- **Untrusted inputs:** jsonl content (Lobster's own output + Discord user messages). Treated as data — only hashed and compared, never executed or injected into shell.
- **Privileged actions:** mutates sessions.json, renames files, calls `openclaw gateway restart`. All scoped to `~/.openclaw/agents/main/` and `~/Library/LaunchAgents/`.
- **Lock:** atomic mkdir, TTL 300s. No PID file trust.
- **No network input:** reads only local files.

## Why This Is Safe To Auto-Fire

The wipe is **non-destructive to work**:
- Session jsonl is preserved as `.reset.loop-<ts>` (nothing deleted).
- Lobster's long-term knowledge lives in memory/knowledge base, not session.
- Worst case false-positive: Lobster starts a fresh session mid-conversation. Annoying, not data-loss.
- Cooldown (600s) caps blast radius if detector itself loops.

## Integration With lobster-monitor.sh

- **Separate script**, separate LaunchAgent. Does NOT merge.
- Reason: lobster-monitor runs every 5 min (resource signals are slow). Loop detector runs every 60s (behavioral signal needs fast response).
- Both share the same wipe logic → extract `wipe-session.sh` helper used by both (refactor lobster-monitor first, then build detector on top).

## Failure Modes

| Failure | Impact | Mitigation |
|---------|--------|------------|
| Detector script crashes | No auto-wipe, manual still works | LaunchAgent auto-restarts; health log monitored |
| False positive wipe | Lobster loses session mid-convo | Cooldown + `.reset.loop-*` preservation |
| Detector misses loop (jsonl format changes) | Regression to manual | Smoke test on fixture jsonl; alert if zero wipes in 7 days seems suspicious? (maybe not — loops SHOULD be rare) |
| Wipe itself fails | Lobster still looping | Discord alert → Jefe intervenes |

## Rollout

1. Phase 0: this doc → Oracle review
2. Phase 3: build `wipe-session.sh` helper, refactor lobster-monitor to use it, build `loop-detector.sh`, write `tests/loop-detector.test.sh` with fixture jsonl
3. Phase 4: KilaBz + Oracle review (code + safety)
4. Deploy to Mini only (Lobster lives there). Monitor loop-events.jsonl for 1 week.

## Locked Parameters (Jefe approved 2026-04-21)

- **Window size:** 2 assistant messages
- **Cooldown:** 600s (10 min) between wipes
- **Alert webhook:** `$DISCORD_WEBHOOK_ALERTS` (separate alerts channel, NOT command-center — prevents self-referential context poisoning when Lobster wakes into fresh session)
- **Cross-channel dupes:** out of scope for v1
- **Hang detector** (no reply within 10 min): deferred to v2 if loop detector doesn't cover it

## Non-Goals

- Fixing the root cause of why Lobster loops (unknown, multi-source). This system treats the symptom.
- Replacing lobster-monitor.sh. Both coexist.
- Detecting loops in other agents (Mack, Mini, etc.) — scope to Lobster for now.
