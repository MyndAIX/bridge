# AGENTS.md — Repo Operating Card

> Copy this template into any repo root as `AGENTS.md`.
> Agents read this file before starting work to understand the codebase.

---

## Architecture

<!-- 2-3 sentences describing what this project is and how it's structured -->
<!-- Example: -->
<!-- FieldVision is a SwiftUI iOS app using SwiftData for persistence and Supabase for cloud sync. -->
<!-- It follows MVVM with a service layer for network/sync operations. -->
<!-- The app targets iOS 17+ and uses no third-party UI frameworks. -->

## Key Files

<!-- List the files an agent MUST read before working on this codebase -->

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Project-specific agent instructions |
| <!-- e.g. App.swift --> | <!-- Entry point, dependency injection --> |
| <!-- e.g. Models/ --> | <!-- SwiftData models --> |
| <!-- e.g. Services/ --> | <!-- Network, sync, auth --> |

## Known Traps

<!-- Things that have burned agents before. Be specific. -->

- <!-- e.g. SwiftData objects are NOT thread-safe — extract values on @MainActor before passing to background tasks -->
- <!-- e.g. SyncManager must be initialized after auth — calling it before login causes a crash -->
- <!-- e.g. The "projects" table in Supabase has RLS enabled — queries return empty without auth token -->

## Test Commands

```bash
# Unit tests
# e.g. xcodebuild test -scheme FieldVision -destination 'platform=iOS Simulator,name=iPhone 16'

# Lint
# e.g. swiftlint lint --strict

# Build check
# e.g. xcodebuild build -scheme FieldVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

## Build Commands

```bash
# Development build
# e.g. xcodebuild build -scheme FieldVision -configuration Debug

# Release build
# e.g. xcodebuild archive -scheme FieldVision -archivePath build/FieldVision.xcarchive
```

## Ownership Map

<!-- Who (which agent or human) owns what parts of the codebase -->

| Module | Owner | Notes |
|--------|-------|-------|
| <!-- e.g. Views/ --> | <!-- Mack --> | <!-- UI layer, SwiftUI views --> |
| <!-- e.g. Services/ --> | <!-- Mack --> | <!-- Sync, network, auth --> |
| <!-- e.g. Infrastructure/ --> | <!-- Lobster --> | <!-- Bridge, watchers, scripts --> |
| <!-- e.g. TASKLIST.md --> | <!-- Lobster --> | <!-- Single-writer, orchestrator only --> |

---

*Template from MyndAIX Task Contract System v1.0*
