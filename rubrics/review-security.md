# KilaBz Security Review Rubric

1. Authentication and authorization checks are enforced server-side and cannot be bypassed by client input.
2. Untrusted input is validated/sanitized before use in queries, command execution, templates, or file paths.
3. Secrets, tokens, API keys, and credentials are not hardcoded or exposed in logs, responses, or source control.
4. Sensitive data handling uses appropriate protections (transport, storage, and redaction where applicable).
5. Privileged actions include least-privilege checks and reject unauthorized roles/tenants.
6. Security-relevant failures are handled safely (no silent pass-through, no insecure fallback).
