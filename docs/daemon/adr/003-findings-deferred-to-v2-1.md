# ADR 003: Findings Tracker Deferred to v2.1

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** Claude web chat, Oracle

## Context

Initial design included `findings/open/fixed/wontfix/` directory subsystem to solve the "findings rot" problem (KilaBz files P1s that never get tracked to resolution). Oracle flagged a P0 race condition in finding closure. Claude web chat argued: shipping a second state machine inside the v1 daemon undermines the goal of reducing complexity — the daemon + task lifecycle is hard enough for v1.

## Decision

Findings tracker is **not** in v2.0 scope. v1 daemon handles **task lifecycle only**.

Findings remain in Notion (as they are today) for v2.0. After the core daemon is stable (~2 weeks post-launch), add filesystem-based findings tracker in v2.1 using the `close-finding` event pattern endorsed by both Oracle and Perplexity Computer.

## Consequences

- v2.0 scope tightens. Five fewer components to build and test.
- Oracle's P0 (findings directory read-lock race) goes away until v2.1, with time to design it properly.
- KilaBz/Oracle/Antman continue to write findings as review output artifacts; no systematic close-loop mechanism in v2.0.
- Persona-level "cross-check current code before rating" rule (added tonight in agent-knowledge/) mitigates the finding-rot problem at the reviewer level in the meantime.
- In v2.1, findings will integrate cleanly via the event-driven architecture we'll have proven in v2.0.

## Alternatives Rejected

- **Ship findings in v2.0.** Rejected — adds complexity to the component we're building specifically to reduce complexity.
- **Skip findings entirely.** Rejected — the finding-rot problem is real and the /audit showed it costs real engineer attention. Just delayed, not abandoned.

## Rule

When v2.0 is stable, open ADR-00X for v2.1 findings tracker using the `close-finding` event pattern.
