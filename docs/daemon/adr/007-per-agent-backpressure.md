# ADR 007: Per-Agent Backpressure (max_concurrent + max_queued)

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** Perplexity Computer (initial finding), Oracle (aligned)

## Context

Perplexity Computer's first review identified backpressure as the biggest blind spot in the original design: without per-agent queue caps, when Codex rate-limits, KilaBz's queue grows unboundedly. The daemon becomes an **amplifier** of transient provider issues — exactly the class of failure already observed in v1.

## Decision

Every agent has explicit concurrency and queue limits in `config.json`:

```json
{
  "agents": {
    "mini":   { "max_concurrent": 1, "max_queued": 5,  "default_timeout_minutes": 45 },
    "kilabz": { "max_concurrent": 2, "max_queued": 10, "default_timeout_minutes": 15 },
    "oracle": { "max_concurrent": 1, "max_queued": 3,  "default_timeout_minutes": 20 },
    "recon":  { "max_concurrent": 2, "max_queued": 10, "default_timeout_minutes": 10 },
    "harley": { "max_concurrent": 1, "max_queued": 5,  "default_timeout_minutes": 30 },
    "antman": { "max_concurrent": 1, "max_queued": 5,  "default_timeout_minutes": 45 },
    "smoke":  { "max_concurrent": 1, "max_queued": 2,  "default_timeout_minutes": 5  }
  }
}
```

Tasks beyond `max_queued` are **deferred**, not **dropped**. Move to `state/deferred/<agent>/` with audit entry `{event: "backpressure", reason: "queue_full"}`. mxd re-ingests deferred tasks when queue clears.

Per-task `timeout_minutes` overrides the agent default.

## Consequences

- Daemon cannot amplify a provider outage into system-wide overload
- Operator sees `state/deferred/` size grow — visible signal that a provider is down or Jefe is overscheduling
- `mx status --agent kilabz` shows `pending: 3, running: 2, deferred: 7` — clear operational picture
- Alert when any agent's deferred count crosses threshold (configurable; default 10)
- Tasks never silently lost; backpressure is explicit and recoverable

## Alternatives Rejected

- **No backpressure (v1 behavior).** Rejected — this was the exact problem.
- **Drop on overflow.** Rejected — silent task loss; Perplexity's recommended "rename-and-warn" pattern applies here too.
- **Global system-wide concurrency limit.** Rejected — too blunt; one slow agent shouldn't throttle fast ones.
