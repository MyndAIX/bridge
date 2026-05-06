# ADR 006: Mack Stays Interactive, No Cloning to Mini

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** Jefe (proposed, then agreed with my analysis not to clone)

## Context

Jefe explored whether to clone Mack's full configuration/skills/persona to Mini, collapsing the Mack/Mini distinction entirely. The reasoning: one Claude, just runs in two places.

Analysis showed Mack and Mini have the same underlying model capability but genuinely different **operating modes**:

| | Mack (interactive) | Mini (autonomous) |
|---|---|---|
| When unclear | Pause, ask Jefe | Commit to best-faith decision |
| Scope of change | Propose, wait for ok | Execute, write result |
| Response style | Short, Jefe drives | Structured, machine-readable |
| Failure mode | Jefe unblocks in seconds | Task hangs → timeout → failed/ |
| Review gate | Real-time by Jefe | Must dispatch to KilaBz before commit |

Full cloning would still require two persona files (interactive vs autonomous) and two sets of prompt scaffolding. No architectural savings.

## Decision

Mack (Claude Code on MacBook) and Mini (Claude CLI on Mac Mini) remain distinct agents with distinct persona files:
- `~/.myndaix/agent-knowledge/mack.md` — interactive mode; pair-program with Jefe
- `~/.myndaix/agent-knowledge/mini.md` — autonomous mode; execute dispatched tasks

Both inherit shared universal rules (`~/.myndaix/rules/`) and skills (`~/.myndaix/skills/`) via Syncthing sync.

## Consequences

- Two persona files to maintain (minor cost)
- Clear role separation in Jefe's mental model
- Mini can behave differently than Mack where different behavior is appropriate (commit vs ask, execute vs propose)
- Skills/rules sync (ADR-008) keeps them aligned on shared principles
- Fidelity tests verify Mini matches Mack's expected patterns for shared behavior classes

## Alternatives Rejected

- **Full clone — rename to "Mack-interactive" and "Mack-autonomous."** Rejected. Same architecture with different names; no gain.
- **Single unified persona with runtime mode detection.** Rejected. Branching logic in persona prompts is harder to read than two files.

## Rule

When developing new capabilities with Jefe, determine whether the capability is:
- Shared (goes in `rules/` or `skills/` — both inherit)
- Interactive-specific (goes in `mack.md` only)
- Autonomous-specific (goes in `mini.md` only)

Most capabilities are shared.
