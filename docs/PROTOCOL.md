# MyndAIX Agent Communication Protocol v1.0

> Multi-agent systems don't fail because the models are dumb. They fail because the communication layer doesn't exist.

## Overview

This protocol defines how AI agents communicate in a multi-agent system. It solves the problems that every multi-agent deployment hits but nobody talks about: silent message loss, competing consumers, untyped messages, no delivery guarantees, and invisible failures.

**Design principles:**
- File-based IPC — inspectable, debuggable, works across machines and models
- Type-based routing — the message type determines where it goes and who handles it
- Separation of concerns — routing is not execution
- Fail-visible — failures surface, never disappear silently

---

## 1. Message Format

Every message is a markdown file with YAML frontmatter:

```markdown
---
id: {timestamp}-{slug}
from: {sender agent}
to: {recipient agent}
type: {message type}
subject: {human-readable subject}
priority: normal | urgent
status: pending
created: {ISO 8601 timestamp}
---

{body — markdown}
```

### Required fields
| Field | Description |
|-------|-------------|
| `id` | Unique identifier: `{YYYYMMDDHHmmss}-{slug}` |
| `from` | Sender agent name |
| `to` | Recipient agent name |
| `type` | Message classification (see Section 2) |
| `subject` | Human-readable subject line |
| `status` | Current state: `pending`, `claimed`, `building`, `review`, `approved`, `rejected`, `merged` |
| `created` | ISO 8601 timestamp |

### Optional fields
| Field | Description |
|-------|-------------|
| `priority` | `normal` (default) or `urgent` |
| `in_reply_to` | ID of the message being replied to |
| `project` | Repository or project path |
| `tier` | Execution tier for task routing |
| `timeout` | Max execution time in seconds |
| `task_id` | External tracking ID (e.g., Notion) |

---

## 2. Message Types

Types determine routing behavior. This is the core of the protocol.

### Actionable types (routed to execution queue)
| Type | Purpose | Consumer |
|------|---------|----------|
| `task` | Work to be executed | Builder agents (Mack, Mini, Antman) |
| `review` | Code review request | Reviewer agents (KilaBz, Oracle) |
| `handoff` | Agent-to-agent task transfer | Receiving agent's watcher |

### Non-actionable types (stay in inbox for interactive reading)
| Type | Purpose | Consumer |
|------|---------|----------|
| `response` | Reply to a previous message | Interactive session |
| `message` | General communication | Interactive session |
| `status` | Status update / alert | Interactive session or dashboard |
| `question` | Request for input | Interactive session |

**Rule: If a new type is introduced and not in the actionable list, it stays in inbox by default. Fail-safe = don't execute unknown types.**

---

## 3. Architecture

```
┌─────────────────────────────────────────────────┐
│                   Senders                        │
│  (agents, orchestrator, external systems)        │
└──────────────────┬──────────────────────────────┘
                   │ write .md file
                   ▼
┌─────────────────────────────────────────────────┐
│              inbox/{agent}/                       │
│  Landing zone — all messages arrive here         │
└──────────────────┬──────────────────────────────┘
                   │ daemon scans every N seconds
                   ▼
┌─────────────────────────────────────────────────┐
│              Daemon (Router)                      │
│                                                   │
│  type ∈ {task, review, handoff}                  │
│    → MOVE to queue/{agent}/                      │
│                                                   │
│  type ∈ {response, message, status, question}    │
│    → LEAVE in inbox/{agent}/                     │
│                                                   │
│  type = unknown                                   │
│    → LEAVE in inbox/{agent}/ (fail-safe)         │
└��─────────┬────────────────────┬─────────────────┘
           │                    │
           ▼                    ▼
┌──────────────────┐  ┌──────────────────────────┐
│ queue/{agent}/    │  │ inbox/{agent}/            │
│                   │  │                           │
│ Watcher consumes  │  │ Interactive session reads │
│ and executes      │  │ Agent checks on demand    │
└──────────────────┘  └──────────────────────────┘
```

### The two rules

1. **The daemon routes. It never executes.** It reads message type, moves actionable messages to the queue, and leaves everything else alone.

2. **Watchers execute. They never route.** They consume from the queue, run the task, write results. They don't touch the inbox.

This separation is what prevents the competing-consumer problem that breaks every naive multi-agent file-based system.

---

## 4. Delivery Guarantees

### Current (v1.0)
- **At-most-once delivery** for actionable messages (atomic `rename` — first daemon to move the file wins)
- **Persistent until read** for non-actionable messages (stay in inbox indefinitely)
- **No acknowledgment** — sender does not know if message was received

### Planned (v2.0)
- **Delivery confirmation** — daemon writes an ACK file to sender's inbox when message is routed
- **Read receipts** — interactive session marks message as read
- **Retry with backoff** — if a message can't be routed (parse error, unknown agent), retry N times before dead-lettering

---

## 5. Health Monitoring

The daemon monitors watcher health as a secondary function.

### Heartbeat contract
Each watcher writes a heartbeat file after every task:
```json
{
  "agent": "mack",
  "last_beat": "2026-03-28T01:35:00Z",
  "last_task": "task-name.md",
  "last_result": "PASS",
  "tasks_today": 22
}
```

Location: `state/{agent}-heartbeat.json`

### Health check logic
Every 60 seconds, the daemon checks:
1. Are there tasks in `queue/{agent}/`?
2. Is the watcher's heartbeat stale (>20 min)?
3. If both: alert. If either is false: no action.

**Only local watchers are monitored.** Each machine's daemon checks its own watchers. Cross-machine health is the orchestrator's responsibility.

### Alert behavior
- Log the alert
- Write alert message to orchestrator's inbox
- Do NOT auto-restart (OS-level process management handles this)
- Do NOT re-alert for the same agent until it recovers

---

## 6. Multi-Machine Operation

When agents run across multiple machines (synced via Syncthing, rsync, or similar):

### Deduplication
- Atomic `rename` is the dedup mechanism. If two daemons race on the same file, the loser gets ENOENT.
- The losing daemon logs `DEDUP` and moves on.
- No shared lock, no database, no coordination — filesystem atomicity is sufficient.

### Machine awareness
- Each daemon knows which watchers are local (based on OS username or config)
- Health checks only monitor local watchers
- Routing is global — every daemon routes for all agents whose inboxes it can see

### Conflict avoidance
- Each machine should be authoritative for its own agents' queues
- Syncthing syncs `inbox/` across machines. `queue/` is local-only.
- This prevents the scenario where both machines' watchers try to execute the same task

---

## 7. Failure Modes (Known)

| Failure | Symptom | Detection | Recovery |
|---------|---------|-----------|----------|
| Daemon down | Messages pile up in inbox | No heartbeat in `state/daemon-heartbeat.json` | KeepAlive LaunchAgent auto-restarts |
| Watcher down | Tasks pile up in queue | Health check alerts orchestrator | LaunchAgent auto-restarts |
| Message has no frontmatter | Can't determine type | Daemon logs parse error, leaves in inbox | Manual repair or `bridge_repair` tool |
| Unknown message type | Could be actionable or not | Daemon logs it | Stays in inbox (fail-safe) |
| Syncthing race | Two daemons route same file | ENOENT on rename | Logged as DEDUP, no action needed |
| Watcher processes non-actionable | Shouldn't be in queue | Watcher logs warning | Archives to processed/ |

---

## 8. Validation Statuses

When a watcher executes a task, the result includes a validation status:

| Status | Meaning |
|--------|---------|
| `PASS` | Task completed successfully |
| `FAILED` | Task execution failed |
| `TIMEOUT` | Task exceeded time limit |
| `CONTEXT_OVERFLOW` | Agent hit context window limit |
| `MERGE_CONFLICT` | Code changes couldn't merge back to main branch |
| `REJECTED` | Task failed pre-execution validation |

---

## 9. Design Decisions and Rationale

**Why files, not a message queue?**
Files are inspectable. You can `ls` an inbox, `cat` a message, `mv` to archive. No database to corrupt, no broker to crash, no protocol to debug. Every AI agent can read and write files regardless of model family.

**Why periodic scan, not file system events?**
macOS fsevents (via chokidar/FSWatch) don't fire reliably under launchd background processes. A 10-second scan is simple, reliable, and fast enough. File system events are kept as a bonus fast-path for interactive sessions.

**Why separate inbox and queue?**
Without this separation, any consumer that reads the inbox competes with every other consumer. The watcher that ran every 10 minutes was archiving replies because it didn't know they weren't tasks. The queue gives watchers a clean, typed input channel.

**Why type-based routing instead of agent-based?**
Agent-based routing (send to KilaBz = it's a review) couples the message to the recipient. Type-based routing (type: review → queue) lets the daemon route without knowing what each agent does. Add a new agent? It just reads from its queue. No daemon changes needed.

---

*Protocol version: 1.0*
*Authors: Mack + Jefe (MyndAIX)*
*Date: 2026-03-27*
*Born from 2 hours of debugging silent message loss.*
