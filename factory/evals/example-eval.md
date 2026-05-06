---
id: EVAL-EXAMPLE-001
title: Magic-link login — eval scorecard
status: draft
owner: kilabz
created: 2026-05-01
related_spec: SPEC-EXAMPLE-001
related_scenarios: [SCEN-EXAMPLE-001]
threshold: 4   # of 5 must pass to ship
---

# EVAL-EXAMPLE-001 — Magic-link login scorecard

> An eval reduces a spec + scenarios to a yes/no answer:
> "Is this safe to ship?" Each row is a concrete check. The threshold
> at the top of frontmatter says how many must pass.

## Scorecard

| # | Check | Pass condition | Result | Notes |
|---|---|---|---|---|
| 1 | Happy path (Scenario A) | Form → email → click → /dashboard ≤ 10s end-to-end | TODO | run via `bin/test-e2e auth-magic-link` |
| 2 | Expired token (Scenario B) | 410 + UX shows resend CTA | TODO | |
| 3 | Reused token (Scenario C) | 410 + no session cookie | TODO | |
| 4 | Rate limit (Scenario E) | 429 with `Retry-After` after 6 submissions/min | TODO | |
| 5 | Token cleanup | No token rows older than 24h after cron run | TODO | run cron, sleep, query |

## Security checklist (gate)

These are P0 — any FAIL blocks ship regardless of scorecard total.

- [ ] Token entropy ≥ 128 bits.
- [ ] Token comparison is constant-time (avoid timing attack).
- [ ] No token is logged or echoed to stdout in any code path.
- [ ] `POST /auth/magic-link` requires CSRF protection if called from a form.
- [ ] Email subject line does not contain the token.

## Sign-off

- Spec author: ___
- Implementer (Mini): ___
- Reviewer (KilaBz): ___
- Architecture review (Oracle): ___
- Date shipped: ___
