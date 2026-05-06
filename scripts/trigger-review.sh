#!/bin/bash
# trigger-review.sh — Auto-trigger KilaBz review for a branch push
# Usage: trigger-review.sh <repo_path> <branch> [commit_count]
set -euo pipefail

REPO="${1:?Usage: trigger-review.sh <repo_path> <branch> [commit_count]}"
BRANCH="${2:?Usage: trigger-review.sh <repo_path> <branch> [commit_count]}"
COMMIT_COUNT="${3:-1}"
KILABZ_INBOX="$HOME/.myndaix/bridge/inbox/kilabz"
TIMESTAMP=$(date -u '+%Y%m%d%H%M%S')

mkdir -p "$KILABZ_INBOX"

# Get diff stats
DIFF_STAT=$(cd "$REPO" && git diff --stat HEAD~${COMMIT_COUNT}..HEAD 2>/dev/null || echo 'unable to generate diff')
CHANGED_FILES=$(cd "$REPO" && git diff --name-only HEAD~${COMMIT_COUNT}..HEAD 2>/dev/null || echo 'unknown')
COMMIT_MSGS=$(cd "$REPO" && git log --oneline -${COMMIT_COUNT} 2>/dev/null || echo 'unknown')
REPO_NAME=$(basename "$REPO")

# Determine risk level
RISK='low'
echo "$CHANGED_FILES" | grep -qiE 'auth|security|migration|billing|stripe|subscription|rls' && RISK='high'
echo "$CHANGED_FILES" | grep -qiE 'config|env|secret|key|token' && RISK='high'

# Determine review depth
DEPTH='light'
[ "$RISK" = 'high' ] && DEPTH='deep'
FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
[ "$FILE_COUNT" -gt 10 ] && DEPTH='deep'

cat > "$KILABZ_INBOX/${TIMESTAMP}-auto-review.md" << TASKEOF
---
from: lobster
to: kilabz
type: review
subject: Auto-review — ${REPO_NAME} push to ${BRANCH}
objective: Review the latest push to ${BRANCH} for bugs, security issues, and code quality
scope: Changed files in the last ${COMMIT_COUNT} commit(s) on ${BRANCH}
branch: ${BRANCH}
priority: P2 — Medium
risk_level: ${RISK}
tier: auto
date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
---

# Auto-Review: ${REPO_NAME} push to ${BRANCH}

**Depth:** ${DEPTH} pass
**Risk:** ${RISK}

## Recent Commits
${COMMIT_MSGS}

## Changed Files
${CHANGED_FILES}

## Diff Stats
${DIFF_STAT}

## Review Focus
- Check for bugs, logic errors, edge cases
- Security issues (especially if risk=high)
- Code quality and consistency


Write your review to \`~/.myndaix/bridge/inbox/lobster/kilabz-review-${TIMESTAMP}.md\` with \`type: result\`.
TASKEOF

echo "Review task created: ${KILABZ_INBOX}/${TIMESTAMP}-auto-review.md (depth=${DEPTH}, risk=${RISK})"
