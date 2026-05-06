---
id: WORKFLOW-EXAMPLE
title: Standard spec → review → build → review pipeline
status: active
created: 2026-05-01
applies_to: SPEC-EXAMPLE-*
---

# WORKFLOW-EXAMPLE — Standard build pipeline

> A workflow is the choreography between agents for a class of work.
> Specs reference one workflow id; the dispatch chain is then deterministic.
> Workflows are short on purpose — if they're long, they're describing
> something that should live in code instead.

## Stages

```
spec drafted (status: draft)
    │
    │ scripts/dispatch.sh --to oracle --type review --branch <branch> --subject "review SPEC-XYZ"
    ▼
Oracle review (architecture + security)
    │
    │ ┌────────────── reject → back to author with comments
    │ │
    │ └────────────── approve → status: active
    ▼
spec status: active → scenarios drafted → evals drafted
    │
    │ scripts/dispatch.sh --to mini --type task --priority P1 --subject "implement SPEC-XYZ"
    ▼
Mini builds against scenarios
    │
    │ scripts/dispatch.sh --to kilabz --type review --branch <branch> --subject "review impl of SPEC-XYZ"
    ▼
KilaBz code review
    │
    │ ┌────────────── reject → back to Mini with diff
    │ │
    │ └────────────── approve → run eval scorecard
    ▼
Eval scorecard ≥ threshold → ship
    │
    │ ┌────────────── below threshold → back to Mini
    │ │
    │ └────────────── threshold met → status: done
    ▼
Postmortem (if anything broke during build)
    │
    └─→ factory/knowledge/postmortems/POSTMORTEM-XYZ.md
        + auto-promote pattern via Upgrade 6 if fingerprint matches ≥3 incidents
```

## Agents per stage

| Stage | Agent | Engine | Output |
|---|---|---|---|
| Spec review | Oracle | Gemini 2.5 Pro CLI | inline comments → `inbox/lobster/<result>.md` |
| Build | Mini | Claude (smart-routed) | branch + commits + result md |
| Code review | KilaBz | Codex (Gemini fallback) | review comments + verdict |
| Eval | KilaBz or Smoke | Claude | scorecard fill-in |
| Architecture sign-off | Oracle | Gemini | go/no-go |

## Frontmatter contract

For a spec to use this workflow, set in the spec's frontmatter:

```yaml
related_workflow: example-workflow
```

Lobster reads the workflow id and dispatches the next stage automatically when an inbox result matches a stage transition (e.g. an Oracle approval triggers the Mini dispatch).

## When NOT to use this workflow

- Trivial typo fixes — go direct: `scripts/dispatch.sh --to mini …`
- Research-only work (no code change) — use Recon, not this pipeline.
- Cross-cutting refactors — define a custom workflow with multiple Mini → KilaBz round-trips.
