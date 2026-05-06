#!/bin/bash
#
# dispatch-oracle-review.sh — Auto-dispatch review to Oracle after build completion
#
# Usage: dispatch-oracle-review.sh <agent> <task_name> <repo> <branch> <worktree> <result_file>
#
# This is the mandatory Oracle review hook. Every successful build triggers
# an async, non-blocking review dispatch to Oracle.
#
# Builds are marked "complete pending review" — Oracle reviews don't block
# the build pipeline from continuing.
#

set -uo pipefail

AGENT="${1:-unknown}"
TASK_NAME="${2:-unknown}"
REPO="${3:-}"
BRANCH="${4:-n/a}"
WORKTREE="${5:-}"
RESULT_FILE="${6:-}"

ORACLE_INBOX="$HOME/.myndaix/bridge/inbox/oracle"
TIMESTAMP=$(date -u '+%Y%m%d%H%M%S')
SUFFIX=$(head -c 4 /dev/urandom | xxd -p | cut -c1-8)
REVIEW_FILE="$ORACLE_INBOX/${TIMESTAMP}-${AGENT}-oracle-review-${SUFFIX}.md"

mkdir -p "$ORACLE_INBOX"

# Build the review dispatch
{
  echo "---"
  echo "id: oracle-review-${TIMESTAMP}-${SUFFIX}"
  echo "from: ${AGENT}"
  echo "to: oracle"
  echo "type: review"
  echo "subject: \"Auto-review: ${TASK_NAME} (${AGENT})\""
  echo "priority: P2"
  echo "status: pending"
  echo "tier: auto"
  echo "created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  [ -n "$REPO" ] && echo "repo: ${REPO}"
  [ -n "$BRANCH" ] && echo "branch: ${BRANCH}"
  echo "objective: Review the build output from ${AGENT} for architecture issues, QA concerns, and blindspots"
  echo "scope:"
  echo "  in:"
  echo "    - ${TASK_NAME}"
  echo "  out:"
  echo "    - unrelated code"
  echo "done_criteria:"
  echo "  - Architecture review with findings dispatched back to lobster"
  echo "---"
  echo ""
  echo "## Mandatory Oracle Review"
  echo ""
  echo "**Agent:** ${AGENT}"
  echo "**Task:** ${TASK_NAME}"
  echo "**Branch:** ${BRANCH}"
  echo "**Worktree:** ${WORKTREE}"
  echo ""
  echo "Review the work completed by ${AGENT} on this task. Focus on:"
  echo "1. Architecture — is the approach sound?"
  echo "2. QA — config changes that need restarts? Missing env vars? Permission issues?"
  echo "3. Blindspots — what did the builder miss?"
  echo ""
  if [ -n "$RESULT_FILE" ] && [ -f "$RESULT_FILE" ]; then
    echo "## Build Output"
    echo ""
    tail -n 200 "$RESULT_FILE"
  fi
} > "$REVIEW_FILE"
