---
id: SCEN-EXAMPLE-001
title: Magic-link login — happy path and edge cases
status: draft
owner: kilabz
created: 2026-05-01
related_spec: SPEC-EXAMPLE-001
---

# SCEN-EXAMPLE-001 — Magic-link login scenarios

> Scenarios are concrete, executable test cases derived from the spec.
> Each scenario is one user story with explicit input → expected output.
> If you can't write the scenario, the spec is too vague.

## Setup

- Empty `tokens` table.
- Test user `alice@example.com` exists in `users` table.
- Test SMTP server captures outbound email (no real send).

## Scenario A — Happy path

**Given** an unauthenticated user on `/login`
**When** they submit `alice@example.com`
**Then**
- A row is inserted in `tokens` with `email='alice@example.com'`, `expires_at=now+15min`, `used=false`.
- An email is captured by the test SMTP server with a `https://app/auth/verify?token=<32-byte-hex>` link.
- HTTP response is 200 with body `{"sent": true}`.

**When** they click the link
**Then**
- The token row is updated: `used=true, used_at=<now>`.
- A session cookie is set.
- HTTP redirects to `/dashboard`.

## Scenario B — Expired token

**Given** a token that was issued 16 minutes ago
**When** the user clicks the link
**Then**
- HTTP 410 Gone with body `{"error": "token_expired"}`.
- Page renders a "request a new link" form.
- No session cookie set.

## Scenario C — Reused token

**Given** a token already used once (status `used=true`)
**When** the user clicks the link a second time
**Then**
- HTTP 410 Gone with body `{"error": "token_used"}`.
- No session cookie set.

## Scenario D — Unregistered email

**Given** an empty `users` table
**When** the user submits `mallory@example.com`
**Then**
- (Per Q2 in spec — open) Either:
  - **A:** HTTP 200 with `{"sent": true}` (anti-enumeration), no email sent.
  - **B:** HTTP 404 with `{"error": "no_account"}`.
- TODO: lock in the behavior before this scenario can pass review.

## Scenario E — Rate limit

**Given** the same email submitted 6 times in 60 seconds
**When** the 7th submission arrives
**Then**
- HTTP 429 Too Many Requests with `Retry-After: 60`.
- No new token row created.
