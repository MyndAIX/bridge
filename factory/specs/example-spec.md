---
id: SPEC-EXAMPLE-001
title: User authentication via magic link
status: draft
owner: cli
created: 2026-05-01
updated: 2026-05-01
priority: P1
related_workflow: example-workflow
---

# SPEC-EXAMPLE-001 — User authentication via magic link

> A spec is the smallest contract that lets an agent build the right thing.
> It answers four questions: **what**, **why**, **what's in**, **what's out**.
> If a reader has to ask the user a question, the spec is missing a section.

## What

Replace the existing username/password login with a magic-link flow:
the user enters their email, receives a one-time link, clicks it, and
lands on the dashboard authenticated.

## Why

- 60% of password resets in our logs are for forgotten passwords.
- Magic links eliminate password storage and the reset flow entirely.
- Security: removes the password-database compromise vector.

## In scope

- New `POST /auth/magic-link` endpoint that emails the link.
- New `GET /auth/verify?token=…` endpoint that consumes the link.
- Token expires after 15 minutes, single-use.
- Email template (plain text, no HTML for v1).

## Out of scope

- Existing password login stays as a fallback (separate spec to remove later).
- 2FA / passkeys — separate spec.
- Customizing the email template — defer to designers.

## Constraints

- No new dependencies. The system already has `nodemailer` and `crypto`.
- All tokens stored in the existing `tokens` table; no schema changes.

## Acceptance criteria

See `evals/EVAL-EXAMPLE-001.md` for the scorecard. The short version:

- [ ] User receives email within 5s of submitting the form.
- [ ] Clicking the link logs them in and redirects to `/dashboard`.
- [ ] Used or expired tokens return 410 Gone with a "request a new link" CTA.
- [ ] No tokens persist beyond 24 hours (cron purge).

## Open questions

> Resolve before status: active.

- Q1: Do we rate-limit `POST /auth/magic-link` per IP or per email? Both?
- Q2: What happens if the user enters an unregistered email — silent success
  (anti-enumeration) or explicit "no account found"?

## History

- 2026-05-01: Created. Pending Oracle review.
