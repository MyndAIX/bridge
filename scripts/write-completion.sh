#!/bin/bash
#
# write-completion.sh — Signal task completion for auto-dispatch verification
#
# Part of MyndAIX 10x Production Plan Phase 2 prep.
# Writes a completion signal that Lobster drains on heartbeat.
# Separate from checkpoint to avoid the overwrite race condition:
#   Agent completes task → writes checkpoint → starts next task →
#   overwrites checkpoint → Lobster reads at heartbeat → misses completion.
#
# Completion signals are append-only. Lobster reads and archives them.
#
# Usage:
#   write-completion.sh --agent mack --task-id MX-001 \
#     --task-name "Fix routing bug" --result PASS
#
# Writes to: state/completions/{timestamp}-{agent}.md
#

set -uo pipefail

COMPLETIONS_DIR="${HOME}/.myndaix/bridge/state/completions"
mkdir -p "$COMPLETIONS_DIR"

AGENT=""
TASK_ID=""
TASK_NAME=""
RESULT="PASS"
REPO=""
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)     AGENT="$2"; shift 2 ;;
    --task-id)   TASK_ID="$2"; shift 2 ;;
    --task-name) TASK_NAME="$2"; shift 2 ;;
    --result)    RESULT="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --branch)    BRANCH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$AGENT" ]]; then
  echo "ERROR: --agent required" >&2
  exit 1
fi

TIMESTAMP=$(date -u '+%Y%m%d%H%M%S')
SIGNAL_FILE="${COMPLETIONS_DIR}/${TIMESTAMP}-${AGENT}.md"

# Atomic write
TMPFILE="${SIGNAL_FILE}.tmp.$$"
{
  echo "---"
  echo "agent: ${AGENT}"
  echo "task_id: ${TASK_ID:-unknown}"
  echo "task_name: ${TASK_NAME:-unknown}"
  echo "result: ${RESULT}"
  [ -n "$REPO" ] && echo "repo: ${REPO}"
  [ -n "$BRANCH" ] && echo "branch: ${BRANCH}"
  echo "completed: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "---"
} > "$TMPFILE"

mv "$TMPFILE" "$SIGNAL_FILE"
