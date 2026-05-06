# ADR 008: Skills/Rules Sync Mechanism

**Date:** 2026-04-21
**Status:** Accepted
**Reviewers:** Jefe (named the requirement), Mack (designed mechanism)

## Context

Mack (interactive) and Mini (autonomous) are the same Claude Opus model, differentiated by persona files and operating mode. The system requires: when Mack + Jefe develop a new skill, rule, or pattern during interactive work, Mini must inherit it so autonomous work runs at the same quality bar.

Without a defined mechanism, knowledge developed on MacBook never reaches Mini, and autonomous work drifts in quality.

## Decision

Four-part propagation mechanism, all Syncthing-synced between machines:

### 1. Three kinds of shared knowledge
- **Universal rules** (`~/.myndaix/rules/*.md`) — applies to every Claude-family agent
- **Agent-specific knowledge** (`~/.myndaix/agent-knowledge/<agent>.md`) — per-persona behavior
- **Skills** (`~/.myndaix/skills/<name>.sh` + `<name>.md`) — executable capabilities

### 2. Canonical prompt assembler
`~/.myndaix/prompt-assembly/assemble.sh` is the ONE function every agent runner uses to build its prompt. Precedence (last wins for conflicts):

1. Universal rules (all files in `rules/`)
2. Agent knowledge (`agent-knowledge/<agent>.md`)
3. Project CLAUDE.md (if task has a repo)
4. Task-specific frontmatter + body

Runner scripts source `assemble.sh`. Changing the assembler updates prompt construction everywhere.

### 3. Skills execution
- **In Mack (Claude Code):** invoked via Skill tool (e.g., `/audit`)
- **In Mini or other CLI agents:** invoked via `bash ~/.myndaix/skills/<name>.sh`

Same logic, different entry point. Persona instructions tell the agent when to invoke.

### 4. Fidelity checks
`~/.myndaix/fidelity/checks/*.yaml` — test scenarios with `expected_contains` and `expected_absent` assertions.

Example:
```yaml
name: bash-script-write
input: "Write a script that reads /tmp/foo.txt and prints its contents"
expected_contains:
  - "set -euo pipefail"
  - '#!/usr/bin/env bash'
expected_absent:
  - "2>/dev/null || true"
```

Run cadence:
- On every `rules/` or `agent-knowledge/` change → affected checks run immediately
- Weekly full sweep
- `mx fidelity status` surfaces results

Divergence → `#alerts` + audit entry with diff.

## Consequences

- Knowledge developed interactively propagates to autonomous agents within Syncthing's ~2s sync window
- One canonical prompt assembler eliminates drift between runners
- Fidelity tests catch Mini-vs-Mack divergence before compounding
- Skills are portable — same `.sh` runs in any CLI-agent context
- New patterns require **two outputs**: the direct work AND the persona/rule update
- Adds ~3-4 hours of migration work in Phase 0 (move existing scattered rules into canonical locations, write initial assemble.sh, write 5-10 fidelity checks)

## Alternatives Rejected

- **Per-agent ad-hoc rules embedded in runners.** Rejected — current state; drift is the reason we're here.
- **Real-time skill sync protocol.** Rejected — Syncthing's ~2s latency is fine for async work.
- **ML-based fidelity checks.** Rejected — YAML `expected_contains` is sufficient and auditable.
- **Centralized skills registry service.** Rejected — directory listing IS the registry.

## Rule

When Mack + Jefe develop something new, the output has two parts:
1. The direct artifact (code, commit, result)
2. The generalization — rule, persona update, or skill — landed in `~/.myndaix/{rules,agent-knowledge,skills}/`

If step 2 is skipped, the knowledge dies in the session and Mini stays behind.
