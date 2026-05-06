#!/bin/bash
#
# dispatch-smoke-qa.sh — Auto-dispatch QA verification to Smoke after build completion
#
# Usage: dispatch-smoke-qa.sh <agent> <task_name> <repo> <branch> <worktree> <result_file>
#
# Triggered by watchers after a successful build. Smoke verifies the build
# compiles, tests pass, and no regressions introduced.
#

set -uo pipefail

AGENT="${1:-unknown}"
TASK_NAME="${2:-unknown}"
REPO="${3:-}"
BRANCH="${4:-n/a}"
WORKTREE="${5:-}"
RESULT_FILE="${6:-}"

SMOKE_INBOX="$HOME/.myndaix/bridge/inbox/smoke"
TIMESTAMP=$(date -u '+%Y%m%d%H%M%S')
SUFFIX=$(head -c 4 /dev/urandom | xxd -p | cut -c1-8)
REVIEW_FILE="$SMOKE_INBOX/${TIMESTAMP}-${AGENT}-smoke-qa-${SUFFIX}.md"

mkdir -p "$SMOKE_INBOX"

# Build the QA dispatch
{
  echo "---"
  echo "id: smoke-qa-${TIMESTAMP}-${SUFFIX}"
  echo "from: ${AGENT}"
  echo "to: smoke"
  echo "type: qa"
  echo "subject: \"QA verify: ${TASK_NAME} (${AGENT})\""
  echo "priority: P2"
  echo "status: pending"
  echo "tier: auto"
  echo "created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  [ -n "$REPO" ] && echo "repo: ${REPO}"
  [ -n "$BRANCH" ] && echo "branch: ${BRANCH}"
  echo "objective: Verify build from ${AGENT} compiles cleanly and passes tests"
  echo "scope:"
  echo "  in:"
  echo "    - ${TASK_NAME}"
  echo "  out:"
  echo "    - unrelated code"
  echo "done_criteria:"
  echo "  - Build compiles without errors"
  echo "  - Existing tests pass"
  echo "  - No regressions in changed files"
  echo "---"
  echo ""
  echo "## Smoke QA Verification"
  echo ""
  echo "**Agent:** ${AGENT}"
  echo "**Task:** ${TASK_NAME}"
  echo "**Branch:** ${BRANCH}"
  echo "**Worktree:** ${WORKTREE}"
  echo ""
  echo "Verify the work completed by ${AGENT}:"
  echo "1. Build compiles without errors"
  echo "2. Run existing tests — all pass"
  echo "3. Check for obvious regressions in changed files"
  echo "4. Report pass/fail back to lobster"
  echo ""
  if [ -n "$RESULT_FILE" ] && [ -f "$RESULT_FILE" ]; then
    echo "## Build Output"
    echo ""
    tail -n 200 "$RESULT_FILE"
  fi
} > "$REVIEW_FILE"
