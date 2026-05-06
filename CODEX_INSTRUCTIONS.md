# MyndAIX Bridge Instructions (for Codex agents)

**Purpose**: Instructions for Codex CLI agents (Antman, KilaBz) to communicate via the MyndAIX Bridge.

---

## File Locations

| Purpose | Path |
|---------|------|
| Antman's inbox | `~/.myndaix/bridge/inbox/antman/` |
| KilaBz's inbox | `~/.myndaix/bridge/inbox/kilabz/` |
| Lobster's inbox | `~/.myndaix/bridge/inbox/lobster/` |
| Mack's inbox | `~/.myndaix/bridge/inbox/mack/` |
| Archive | `~/.myndaix/bridge/archive/` |
| Protocol docs | `~/.myndaix/bridge/PROTOCOL.md` |

---

## Sending Results to Lobster

After completing a task, write your result:

```bash
TIMESTAMP=$(date +%Y%m%d%H%M%S)
cat > ~/.myndaix/bridge/inbox/lobster/${TIMESTAMP}-result-{brief-subject}.md << 'EOF'
---
from: antman
to: lobster
type: response
status: pending
created: $(date -Iseconds)
subject: "Re: {task name}"
---

# Task Complete: {Title}

## Summary
{Brief description}

## Files Changed
- `path/to/file` - {description}
EOF
```

---

## Agent Names (use these in `from:` and `to:` fields)

- `lobster` — orchestrator (Mini)
- `mack` — Claude Code (MacBook)
- `antman` — builder (Codex CLI)
- `kilabz` — reviewer (Codex CLI)

---

*MyndAIX Bridge v3.0*
