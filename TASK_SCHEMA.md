# MyndAIX Task Contract Schema

**Version:** 1.0
**Updated:** 2026-03-22
**Status:** Active — all agents must comply

---

## Overview

Every task, review, result, and message that flows through the bridge system
must use YAML frontmatter conforming to this schema. The validator script
(`scripts/validate-task.sh`) enforces these rules at intake.

---

## Message Types

| Type | Purpose | Example |
|------|---------|---------|
| `task` | Work assignment | "Build the login screen" |
| `review` | Code/design review request | "Review offline sync changes" |
| `research` | Research brief for Recon | "Research Playwright session best practices" |
| `response` | Reply to a task or question | "Here's the info you asked for" |
| `result` | Completed work delivery | "Task T-045 done, here's what changed" |
| `message` | General communication | "Heads up, Mini is rebooting" |
| `alert` | Urgent notification | "Build is broken on main" |

---

## Task Contract — Required Fields

Every message MUST include these fields in YAML frontmatter:

```yaml
---
from: lobster          # sending agent: lobster, mack, jefe, mini, antman, kilabz, recon
to: mack               # receiving agent
type: task             # task | review | response | result | message | alert
subject: "Build login screen with biometric auth"   # one-line description
---
```

### Additional required fields by type:

#### `type: task`

```yaml
objective: "Implement biometric login using LocalAuthentication framework"
scope:
  in: ["LoginView.swift", "AuthManager.swift"]
  out: ["NetworkLayer/", "anything server-side"]
done_criteria:
  - "Face ID / Touch ID prompt appears on launch"
  - "Fallback to passcode works"
  - "Unit tests pass"
priority: P1           # P0 (critical) | P1 (high) | P2 (medium) | P3 (low)
tier: auto             # auto (watcher picks up) | manual (human triggers) — REQUIRED
```

#### `type: review`

```yaml
objective: "Review offline sync implementation for data loss risks"
scope:
  in: ["SyncManager.swift", "OfflineQueue.swift"]
  out: ["UI layer"]
branch: "feature/offline-sync"
tier: auto             # auto (watcher picks up) | manual (human triggers) — REQUIRED
```

#### `type: research`

```yaml
objective: "Research Playwright session persistence and LinkedIn bot detection"
scope:
  in: ["Playwright docs", "LinkedIn automation best practices"]
  out: ["Implementation — research only"]
priority: P1
tier: auto
```

#### `type: result`

```yaml
status: completed      # completed | failed | blocked | timeout
summary: "Built biometric login. Face ID and Touch ID both work. Added 3 unit tests."
changed_files:
  - "LoginView.swift"
  - "AuthManager.swift"
  - "AuthManagerTests.swift"
validation: "All unit tests pass. Manual test on iPhone 15 Pro."
risks: "None — no existing auth logic was modified."
next_actions:
  - "KilaBz should review AuthManager.swift"
  - "Merge to main after review"
```

#### `type: message` or `type: response`

No additional required fields beyond the base four (`from`, `to`, `type`, `subject`).

#### `type: alert`

No additional required fields beyond the base four, but `priority` is strongly recommended.

---

## Optional Fields (All Types)

```yaml
risk_level: low        # none | low | medium | high — does this touch prod?
escalation: "Ask the user if scope grows beyond 2 files"
repo: "~/Desktop/FieldVision"
branch: "feature/biometric-login"
# NOTE: tier is REQUIRED for task and review types (see above). Optional for other types.
date: "2026-03-22"
created: "2026-03-22T14:30:00Z"
task_id: MX-30         # STRONGLY RECOMMENDED — links Notion board → bridge file → Discord thread. Without this, Notion sync relies on fuzzy text matching.
context_files:
  - "docs/research/auth-architecture.md"
  - "CLAUDE.md"
related_tasks:
  - T-048
  - T-049

# Agent-to-agent dispatch (see "Direct Dispatch" section below)
dispatch_to: kilabz    # forward to this agent after completion (on PASS only)
chain:                 # origin chain — tracks dispatch history
  - lobster
  - mini
dispatched_by: mini    # which agent forwarded this task (set by agent-dispatch.sh)
```

---

## Priority Levels

| Level | Meaning | SLA |
|-------|---------|-----|
| `P0` | Critical — prod is broken, data loss risk | Drop everything, fix now |
| `P1` | High — blocks other work | Next up in queue |
| `P2` | Medium — important but not blocking | Current batch |
| `P3` | Low — nice to have, backlog | When bandwidth allows |

---

## Risk Levels

| Level | Meaning | Action |
|-------|---------|--------|
| `none` | No risk — docs, tests, internal tooling | Auto-approve |
| `low` | Minor risk — non-critical code changes | Normal review |
| `medium` | Moderate risk — touches user-facing code | Careful review, test plan required |
| `high` | High risk — touches prod, payments, auth, data | user must approve before merge |

---

## File Naming Convention

```
{YYYYMMDDHHMMSS}-{from}-{type}-{slug}.md
```

Examples:
- `20260322143000-lobster-task-build-login.md`
- `20260322150000-mack-result-login-complete.md`
- `20260322151000-kilabz-review-login-auth.md`

---

## Result Envelope

Every completed task MUST return a result using `type: result`. The result envelope
ensures traceability and lets the orchestrator update TASKLIST.md accurately.

### Required Result Fields

| Field | Type | Description |
|-------|------|-------------|
| `from` | string | Agent that did the work |
| `to` | string | Agent that assigned the work (usually lobster) |
| `type` | string | Must be `result` |
| `status` | enum | `completed`, `failed`, `blocked`, `timeout` |
| `summary` | string | 2-3 sentence summary of what was done |
| `changed_files` | list | Every file modified |
| `validation` | string | What was tested/verified |
| `risks` | string | Any risks introduced (or "None") |
| `next_actions` | list | What should happen next |

### Optional Result Fields

| Field | Type | Description |
|-------|------|-------------|
| `task_id` | string | Links back to TASKLIST.md entry |
| `commit` | string | Commit hash |
| `branch` | string | Branch name |
| `duration` | string | How long the work took |
| `blockers_hit` | list | Problems encountered |

---

## Validation

All tasks are validated at intake by `scripts/validate-task.sh`.
Invalid tasks are rejected with a `REJECTED-` prefix and a rejection
notice is sent to the sender's inbox.

See `examples/` for well-formed task files.

---

## Watcher Integration

Every watcher MUST validate incoming tasks before processing.
Add this block at the top of your task processing loop:

```bash
# --- Task Contract Validation ---
VALIDATOR="$HOME/.myndaix/bridge/scripts/validate-task.sh"

for TASK_FILE in "$INBOX_DIR"/*.md; do
    [[ -f "$TASK_FILE" ]] || continue

    if ! "$VALIDATOR" "$TASK_FILE"; then
        # Extract sender from frontmatter
        SENDER=$(awk '/^---$/{if(++c==1){next}if(c==2){exit}}c==1{print}' "$TASK_FILE" \
            | grep '^from:' | sed 's/from:[[:space:]]*//')

        # Write rejection notice to sender's inbox
        REJECT_FILE="$HOME/.myndaix/bridge/inbox/${SENDER}/$(date +%Y%m%d%H%M%S)-rejected-$(basename "$TASK_FILE")"
        cat > "$REJECT_FILE" << REJECTION
---
from: $(basename "$INBOX_DIR")
to: ${SENDER}
type: response
subject: "REJECTED: $(basename "$TASK_FILE") — missing required fields"
---

# Task Rejected

Your task file \`$(basename "$TASK_FILE")\` failed validation.
Run \`validate-task.sh\` against your file to see which fields are missing.

Refer to \`TASK_SCHEMA.md\` for the required fields.
REJECTION

        # Archive original with REJECTED prefix
        mv "$TASK_FILE" "$HOME/.myndaix/bridge/processed/REJECTED-$(basename "$TASK_FILE")"
        continue
    fi

    # --- Task is valid, proceed with processing ---
    # ... your task processing logic here ...
done
```

---

## Agent-to-Agent Direct Dispatch

Agents can route tasks directly to other agents without going through Lobster.
Lobster always receives a CC notification for visibility.

### How it works

1. A task includes `dispatch_to: <agent>` in frontmatter
2. When the executing watcher completes the task with `PASS`, it calls
   `scripts/agent-dispatch.sh` to forward the task to the target agent
3. The forwarded task gets a `chain` field tracking the dispatch history
4. Lobster's inbox receives a CC message for every agent-to-agent dispatch

### Dispatch fields

| Field | Type | Description |
|-------|------|-------------|
| `dispatch_to` | string | Target agent to forward to after completion |
| `chain` | list | Origin chain — who dispatched to whom (e.g., `[lobster, mini]`) |
| `dispatched_by` | string | Which agent forwarded this task |

### Authorized routes

Not all agents can dispatch to all others. Current authorized routes:

| Sender | Can dispatch to |
|--------|----------------|
| `lobster` | mini, antman, kilabz, mack, recon, harley |
| `mini` | antman, kilabz, mack |
| `antman` | kilabz, mini |
| `kilabz` | mini, antman |
| `mack` | antman, kilabz |

### Example: Mini dispatches to KilaBz for review

```yaml
---
from: lobster
to: mini
type: task
subject: "Build offline sync manager"
objective: "Implement offline-first data sync"
scope:
  in: ["SyncManager.swift"]
  out: ["UI/"]
done_criteria:
  - "Offline queue persists across app restarts"
priority: P2
tier: auto
dispatch_to: kilabz
---
```

After Mini completes this task, the watcher automatically forwards it to
KilaBz for review. The forwarded task includes `chain: ["lobster", "mini"]`
and Lobster receives a CC notification.

### Script usage

```bash
# Manual dispatch (from any agent script)
~/.myndaix/bridge/scripts/agent-dispatch.sh <target> <task-file> <sender> [branch]

# Example: Mini dispatches a review to KilaBz
agent-dispatch.sh kilabz /path/to/task.md mini mini/feature-branch
```

---

*MyndAIX Task Contract Schema v1.1 — updated 2026-03-22 (added agent-to-agent dispatch)*
