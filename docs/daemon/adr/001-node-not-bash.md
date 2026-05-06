# ADR 001: mxd is Node.js, not bash

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** Claude web chat (pushed this decision), Perplexity Computer (aligned)

## Context

The v1 daemon (`myndaix-daemon.js`) was already Node.js. The v2 rebuild initially considered bash for the new `mxd` because the rest of the agent fleet (watchers, runners, hooks) is bash. Claude web chat pushed back: the daemon is the single most critical component — it owns all state mutations — and bash has no structured error handling, no native JSON, and silent failure modes.

## Decision

`mxd` is implemented in Node.js. TypeScript preferred for type safety on schema contracts.

## Consequences

- Proper structured error handling via try/catch, no `|| true` patterns swallowing errors
- Native JSON parse/stringify with validation via JSON Schema (ajv)
- Atomic `fs.rename` natively; `fs.promises.appendFile` for audit log
- Joins existing Node.js ecosystem (v1 daemon, mcp-bridge-server)
- Slightly higher cold-start cost vs bash; immaterial for a long-running daemon
- Language boundary between mxd (Node) and agents/watchers (bash) — acceptable because the daemon IS the boundary by design

## Alternatives Rejected

- **Bash.** Rejected because bash silent-failure modes (e.g., `|| true`, stderr suppression) are the exact class of bug we're building the daemon to prevent.
- **Python.** Viable but adds a third language to the stack for no gain over Node.
- **Rust/Go.** Overkill for a ~200-line daemon; deployment/build complexity not worth the benefit.

## Rule for remaining bash

If bash stays anywhere in the system (runners, hooks, agent invocation scripts), the following are non-negotiable:
- `set -euo pipefail` at top
- Explicit `trap 'cleanup' EXIT INT TERM`
- `shellcheck` in CI
- `jq` for every JSON operation (no string interpolation)
