# ADR 004: Single-Writer Daemon on Mini Only

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** Jefe (architectural vision), supersedes Perplexity Computer's MacBook+Mini peer-daemon proposal

## Context

Perplexity's initial v2 architecture proposed `mxd` running on both machines (MacBook and Mini) with a `machine_target` field on each task to prevent races. This assumed the MacBook would be always on.

Jefe clarified: the MacBook is NOT always on. Jefe opens the laptop specifically to pair-program with Mack (Claude Code). The MacBook is an interactive workbench, not infrastructure. Mini is the always-on hub.

## Decision

`mxd` runs **only on Mini**. MacBook does not run a daemon. State directories (`state/pending/`, `state/running/`, etc.) and `audit.jsonl` live on Mini and are the authoritative copies.

Syncthing replicates `state/` and `audit.jsonl` to MacBook as **read-only projections**. MacBook observes state; it does not mutate it.

## Consequences

- `machine_target` field — eliminated. Not needed.
- Single-writer invariant holds trivially — one process, one machine writes to `state/`.
- Syncthing race conditions on state files — eliminated.
- Cross-machine handoff logic — eliminated.
- MacBook can inspect state any time via Syncthing read-only view.
- If Mini dies, the system is down until Mini comes back. This is the accepted tradeoff (see ADR-005 for failover plan).
- Mack (Claude Code on MacBook) dispatches via `mx dispatch`, which writes tasks directly to Mini's inbox via the existing Syncthing sync (writes are actually on MacBook's disk first, sync'd to Mini, picked up by Mini's mxd).

## Alternatives Rejected

- **Peer daemons on both machines.** Rejected — MacBook not always on; needless complexity.
- **Active-passive failover (standby daemon on MacBook).** Deferred — v2.0 uses manual cold failover only (see ADR-006).

## Single-Writer Enforcement

`mxd` on Mini periodically scans `state/` for mutations whose mtime/ctime indicate a non-mxd writer (e.g., wrong uid/hostname in file owner metadata). Any such mutation logs a protocol violation to `audit.jsonl` and posts to `#alerts`. This catches accidental MacBook writes before they corrupt state.

## Rule

**Never edit `state/` by hand on MacBook.** Ever.
