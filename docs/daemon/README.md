# docs/daemon/ — MyndAIX v2 Control-Plane Documentation

Structured design documentation for the v2 rebuild. See `../research/perplexity-architecture-v2.md` for the canonical architecture reference.

## Layout

- `adr/` — Architecture Decision Records, one file per decision, immutable once committed
- `schemas/` — JSON Schema files for task, audit entry, config (machine-validatable contracts)
- `runbooks/` — Operational procedures read under stress (failover, rollback, recovery)
- `migration/` — Phased migration checklists (Phase 0 → Phase 3)
- `fixtures/` — Concrete valid/invalid examples for testing

## Conventions

- **ADRs** are numbered sequentially (`001-*.md`, `002-*.md`), include Context / Decision / Consequences / Alternatives-Rejected sections, and are never retroactively edited. If a decision is reversed, write a new ADR that supersedes the old one.
- **Schemas** use JSON Schema draft-07. Every agent that writes or reads a task/audit entry validates against the schema.
- **Runbooks** are plain numbered steps. No philosophy, no background. You read them at 2am.
- **Migration** checklists have success criteria per phase and explicit rollback paths.
