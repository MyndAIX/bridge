# MyndAIX Bridge Protocol

**Purpose**: Enable multi-agent coordination through file-based messaging.
**Version**: 2.0
**Updated**: 2026-02-28

---

## Architecture

```
~/.myndaix/bridge/
├── inbox/
│   ├── lobster/     # 🦞 Messages FOR Lobster (orchestrator, Mini)
│   ├── mack/        # 🤖 Messages FOR Mack (Claude Code, MacBook)
│   ├── antman/      # 🐜 Messages FOR Antman (builder agent)
│   └── kilabz/      # 🐝 Messages FOR KilaBz (reviewer agent)
├── archive/         # Processed messages
└── PROTOCOL.md      # This file
```

**Symlinks for backwards compatibility:**
- `inbox/claude/` → `inbox/lobster/`
- `inbox/builder/` → `inbox/antman/`
- `inbox/codex-review/` → `inbox/kilabz/`

---

## Agents

| Agent | Emoji | Inbox | Role | Runtime |
|-------|-------|-------|------|---------|
| **Lobster** | 🦞 | `inbox/lobster/` | Orchestrator, architect | 24/7 on Mini |
| **Mack** | 🤖 | `inbox/mack/` | Builder (Claude Code) | Session-based, MacBook |
| **Antman** | 🐜 | `inbox/antman/` | Builder (Codex CLI) | 2-min cron, Mini |
| **KilaBz** | 🐝 | `inbox/kilabz/` | Reviewer (Codex CLI, read-only) | 2-min cron, Mini |

---

## Message Format

All messages use YAML frontmatter:

```markdown
---
id: {YYYYMMDDHHMMSS}-{slug}
from: lobster | mack | antman | kilabz
to: lobster | mack | antman | kilabz
type: task | response | question | handoff | status
priority: normal | urgent
status: pending | claimed | building | review | approved | rejected | merged
created: {ISO timestamp}
---

# {Subject Line}

{Message body in markdown}
```

---

## Routing Rules

1. **One inbox per agent.** All messages — tasks, responses, replies — go to `inbox/{agent}/`.
2. **No separate `messages/` directory.** Everything routes through `inbox/`.
3. **`bridge_send` and `bridge_reply` are the only send functions.**
4. **Each watcher reads one inbox** — the one named after their agent.
5. **Old names (`claude`, `builder`, `codex-review`) are aliased** to new names for transition.

---

## Processing Messages

### For any agent (when starting session)

```bash
# Check for messages
ls ~/.myndaix/bridge/inbox/{your-name}/

# Read pending messages
cat ~/.myndaix/bridge/inbox/{your-name}/*.md

# After processing, archive
mv ~/.myndaix/bridge/inbox/{your-name}/processed.md ~/.myndaix/bridge/archive/
```

---

## Task State Machine

```
pending → claimed → building → review → approved → merged
                                  ↓
                              rejected → building (rework)
```

---

## Best Practices

1. **One task per message** — keep messages focused
2. **Include context** — don't assume the other agent remembers
3. **Be explicit about expectations** — what output format? What files?
4. **Use real agent names** in `from:` field — lobster, mack, antman, kilabz
5. **Archive processed messages** — keeps inboxes clean

---

*MyndAIX Bridge Protocol v2.0*
