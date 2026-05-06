# ADR 005: Lobster Preserved as Discord Interface

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** Jefe (corrected earlier "nuke Lobster" direction)

## Context

Initial v2 proposals (mine + Perplexity Computer) eliminated Lobster entirely, moving orchestration to Claude Code. Jefe pushed back: killing Lobster would destroy mobile/job-site workflow because Discord is the operator's primary async interface when not at the laptop.

## Decision

Lobster survives in v2, but his role is dramatically reduced:

| v1 Lobster | v2 Lobster |
|---|---|
| Orchestration logic | Removed (mxd owns it) |
| Session management (517 lines) | Removed |
| State tracking | Removed (state lives in mxd) |
| Monitor loop | Removed (`lobster-monitor.sh` → mxd heartbeat) |
| Discord relay | Kept (now a thin `mx dispatch` wrapper) |
| Persona | Kept (operator still interacts with "Lobster" conversationally) |

Target: ~100-line Discord bot on Mini that:
1. Receives Discord messages in #command-center
2. Parses intent (slash commands or natural language)
3. Calls `mx dispatch <agent> <task>` internally
4. Tails `audit.jsonl` for completion events
5. Posts results back to Discord

Lobster is now a **consumer** of mxd, not a peer.

## Consequences

- Mobile/job-site access preserved — Jefe dispatches from his phone via Discord
- 24/7 availability of the orchestrator (Mini is always on)
- Multi-channel visibility (per-agent Discord channels for broadcast work status)
- Conversational dispatch retained as a UX affordance
- Lobster complexity reduced ~95% (~100 LOC target vs 517+ LOC v1)
- No more phantom-loop symptoms (auto-review hook that caused them is dead; Lobster's actual LLM doesn't loop)

## Alternatives Rejected

- **Nuke Lobster entirely; Claude Code is sole orchestrator.** Rejected — breaks mobile access; MacBook not always on.
- **Keep Lobster as full v1 orchestrator.** Rejected — duplicate state with mxd, source of all v1 pain.
- **Replace Discord with SMS/text.** Rejected — loss of multi-channel visibility, rich formatting, per-agent channels, alert bot infrastructure.

## Rule

If Lobster's codebase exceeds 200 lines, we've regressed to v1. Periodic `wc -l` check in CI.
