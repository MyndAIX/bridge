---
from: lobster
to: kilabz
type: review
subject: "Review offline sync queue for data loss risks"
task_id: T-056
priority: P1
risk_level: high
repo: "~/Desktop/FieldVision"
branch: "feature/offline-sync-v2"
created: "2026-03-22T15:00:00Z"
objective: "Audit the offline sync queue implementation for race conditions, data loss scenarios, and conflict resolution gaps. Focus on what happens when the device comes back online after extended offline periods."
scope:
  in:
    - "FieldVision/Services/SyncManager.swift"
    - "FieldVision/Services/OfflineQueue.swift"
    - "FieldVision/Services/ConflictResolver.swift"
    - "FieldVision/Models/SyncOperation.swift"
  out:
    - "UI layer"
    - "Supabase server-side functions"
    - "Push notification handling"
escalation: "Flag to the user if you find any scenario where user data could be silently lost"
context_files:
  - "docs/research/swiftdata-audit.md"
related_tasks:
  - T-015
  - T-016
  - T-013
---

# Review offline sync queue for data loss risks

Mack built the offline sync v2 system in T-048. Before we merge to main, we need a thorough review focused on data integrity.

## Review Checklist

- [ ] Race conditions between sync operations
- [ ] What happens when two devices edit the same record offline
- [ ] Queue ordering — are operations replayed in the correct order
- [ ] Error handling — does a failed sync retry or silently drop
- [ ] Memory pressure — what if the queue grows to 1000+ operations
- [ ] SwiftData thread safety — are all model accesses on the right actor
- [ ] Conflict resolution — last-write-wins or something smarter

## Output Format

Provide findings as:
- CRITICAL: Must fix before merge
- WARNING: Should fix soon
- INFO: Good to know, not blocking
