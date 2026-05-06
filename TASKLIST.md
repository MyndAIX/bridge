# MyndAIX Task List

**Read this file at every session start. Check it on every heartbeat. This is the source of truth.**

## Protocol

- **Single-writer rule.** Only Lobster edits this file. Antman/KilaBz submit results to `inbox/lobster/`, Lobster updates status here.
- **Stable task IDs.** Every task has a `T-XXX` ID. Reference tasks by ID, not row number.
- **DONE requires artifact.** No marking DONE without a file path or commit hash proving it.
- **Batches of 3-4 tasks.** Finish the current batch before starting the next.
- **Route work:** Antman = build/mechanical, KilaBz = review/audit, Lobster = orchestrate/consultd/architecture.
- **When blocked:** Mark `BLOCKED: reason`, move to next task. Don't burn time.
- **Circuit breaker:** 3 fails on same task → mark BLOCKED, move on.
- **When batch is done:** Bridge results to `inbox/mack/`, start next batch.

### Failover Routing

| Primary | If down, route to |
|---------|-------------------|
| Antman  | Mack (MacBook)    |
| KilaBz  | Lobster (self-review) |
| Mack    | Antman            |

## Status Key

- `TODO` — Not started
- `IN_PROGRESS @HH:MM` — Currently working (stale if >30min without update)
- `DONE @HH:MM` — Complete, artifact verified
- `BLOCKED: reason` — Can't proceed
- `DELEGATED:agent @HH:MM` — Sent to agent, awaiting result

---

## Your tasks here

Replace this section with your actual batches. Conventions:

- One **active** batch at a time. Drop completed batches into `## Completed`.
- 3–4 tasks per active batch. Finish before starting the next.
- Each row: `| T-XXX | one-line description | Owner | Status | Artifact path or commit |`.

## BATCH 1 — ACTIVE

| ID | Task | Owner | Status | Output |
|----|------|-------|--------|--------|
| T-001 | (your first task) | mini | TODO | — |
| T-002 | (your second task) | kilabz | TODO | — |
| T-003 | (your third task) | oracle | TODO | — |

## Completed

(Move done tasks here once their artifact is verified.)

| ID | Task | Completed | Artifact |
|----|------|-----------|----------|
