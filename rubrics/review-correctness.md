# KilaBz Correctness Review Rubric

1. The implementation matches stated requirements/objective without missing required behavior.
2. Core logic is functionally correct for normal flows and key edge cases.
3. Error handling and return paths are consistent, explicit, and do not hide failures.
4. Data/state transitions are coherent (no stale state, races, or invalid assumptions across steps).
5. External interfaces (function contracts, schema usage, I/O) are used correctly and consistently.
6. Tests or verifiable checks cover critical behavior introduced or changed.
