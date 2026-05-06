# MyndAIX Bridge Setup (for Mack / Claude Code)

**For the MacBook Claude Code session.**

---

## Your Identity

You are **Mack** 🤖, the MacBook builder. You work directly with Jefe via Claude Code.

## File Locations

```
~/.myndaix/bridge/
├── inbox/
│   ├── lobster/     # 🦞 Lobster's inbox (write responses here)
│   ├── mack/        # 🤖 YOUR inbox (check here for messages)
│   ├── antman/      # 🐜 Antman's inbox
│   └── kilabz/      # 🐝 KilaBz's inbox
├── archive/         # Processed messages
└── PROTOCOL.md      # Full message format
```

## Session Start Checklist

```bash
# 1. Check for messages from Lobster or other agents
ls ~/.myndaix/bridge/inbox/mack/
cat ~/.myndaix/bridge/inbox/mack/*.md 2>/dev/null || echo "No messages"

# 2. After processing, archive
mv ~/.myndaix/bridge/inbox/mack/*.md ~/.myndaix/bridge/archive/
```

## Sending Messages

Use the MCP bridge tools:
- `bridge_send to=lobster ...` — send to Lobster
- `bridge_send to=antman ...` — send to Antman (builder)
- `bridge_send to=kilabz ...` — send to KilaBz (reviewer)
- `bridge_reply ...` — reply to any message

The MCP server auto-detects you as `mack` based on your machine's username.

## Agent Names

- `lobster` — orchestrator (Mini)
- `mack` — you (MacBook)
- `antman` — builder (Codex CLI, Mini)
- `kilabz` — reviewer (Codex CLI, Mini)

Legacy aliases (`claude`, `builder`, `codex-review`) still work but use real names.

---

*MyndAIX Bridge v3.0*
