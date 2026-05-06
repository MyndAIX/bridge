# Factory — Spec-Driven Build Loop

The factory is where the system **operates on its own work**. The bridge in `~/.myndaix/bridge/` is plumbing; the factory is the workshop. Every long-running build effort lives here as a chain of markdown files: spec → scenarios → evals → workflow → knowledge → dashboards.

## When you'd use this

CLI dispatch (Tier 1) and Discord/OpenClaw (Tier 2) are great for one-off tasks. But once you start building real features that take a week of agent-hours each, you want:

- A single place to capture *what* you're building (`specs/`)
- A single place to capture *how you'd know it works* (`scenarios/`, `evals/`)
- A single place to define *which agents touch it in what order* (`workflows/`)
- A single place to capture *what the team has learned* (`knowledge/`)
- A single place to read the current state of all the above (`dashboards/`)

If you can answer "what's our current build status?" by `cat`-ing one or two files in `factory/dashboards/`, the factory is doing its job.

## Layout

```
factory/
├── README.md                     # this file
├── workflows/
│   └── example-workflow.md       # which agents handle what, in what order
├── specs/
│   └── example-spec.md           # what to build
├── scenarios/
│   └── example-scenario.md       # how it should behave under stress
├── evals/
│   └── example-eval.md           # acceptance criteria + scoring
├── knowledge/
│   ├── patterns/                 # reusable architectural patterns (auto-promoted via Upgrade 6)
│   ├── runbooks/                 # how-to-recover docs
│   └── postmortems/              # what went wrong and what changed
└── dashboards/                   # rendered status (typically auto-generated)
```

## Frontmatter conventions

Every file in `factory/` carries YAML frontmatter so Lobster, Oracle, and dispatch scripts can route on metadata. The exact keys are documented in each example file. The minimum:

```yaml
---
id: <stable-id>           # e.g. SPEC-AUTH-001
title: <short title>
status: draft|active|done|abandoned
owner: <agent-or-username>
created: 2026-MM-DD
updated: 2026-MM-DD
---
```

`id` should be unique within a directory; agents reference factory items by id, not path.

## How files connect

```
specs/SPEC-AUTH-001.md
        │
        │ (Oracle reviews → approves)
        ▼
scenarios/SCEN-AUTH-001-{a,b,c}.md   ← test cases derived from spec
        │
        │ (Mini implements → KilaBz reviews)
        ▼
evals/EVAL-AUTH-001.md               ← scorecard against scenarios
        │
        │ (passes → promoted)
        ▼
knowledge/patterns/auth-pattern-1.md ← if reusable
knowledge/postmortems/auth-incident-2.md ← if it broke and you fixed it
```

The full flow lives in `workflows/example-workflow.md`. Adopters typically write one workflow file per major project (e.g. `workflows/my-app.md`) and reuse it across many specs.

## Weekly auto-audit

The `ai.myndaix.weekly-audit` LaunchAgent (registered Sundays via `launchd/templates/`) dispatches Recon to scan `factory/specs/` for stale items (status: active, no update in 14 days) and post a digest to Lobster. This is opt-in — the LaunchAgent template ships disabled.

## Start small

Don't build all six subdirectories at once. The minimum useful factory is `specs/` + `evals/` + one `workflows/` file. Add `scenarios/`, `knowledge/`, and `dashboards/` as your team's needs grow.
