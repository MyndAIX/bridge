#!/bin/bash
#
# write-checkpoint.sh — Write structured agent checkpoint after task completion
#
# Part of MyndAIX 10x Production Plan Phase 1.
# Every agent writes a checkpoint after completing a task.
# Lobster reads all checkpoints on heartbeat to build situational awareness.
#
# Usage:
#   write-checkpoint.sh --agent mack \
#     --topic "bridge routing fix" \
#     --completed "Built daemon, fixed routing" \
#     --decisions "Periodic scan over fsevents" \
#     --next "Deploy to Mini" \
#     [--task-id MX-001] \
#     [--blockers "none"]
#
# Writes to: state/{agent}-checkpoint.md
#

set -uo pipefail

STATE_DIR="${HOME}/.myndaix/bridge/state"

AGENT=""
TOPIC=""
COMPLETED=""
DECISIONS=""
NEXT=""
TASK_ID=""
BLOCKERS="none"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)     AGENT="$2"; shift 2 ;;
    --topic)     TOPIC="$2"; shift 2 ;;
    --completed) COMPLETED="$2"; shift 2 ;;
    --decisions) DECISIONS="$2"; shift 2 ;;
    --next)      NEXT="$2"; shift 2 ;;
    --task-id)   TASK_ID="$2"; shift 2 ;;
    --blockers)  BLOCKERS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$AGENT" ]]; then
  echo "ERROR: --agent required" >&2
  exit 1
fi

CHECKPOINT_FILE="${STATE_DIR}/${AGENT}-checkpoint.md"
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Atomic write
TMPFILE="${CHECKPOINT_FILE}.tmp.$$"
{
  echo "---"
  echo "agent: ${AGENT}"
  echo "timestamp: ${TIMESTAMP}"
  echo "session_topic: ${TOPIC:-unknown}"
  [[ -n "$TASK_ID" ]] && echo "task_id: ${TASK_ID}"
  echo "---"
  echo ""
  echo "## Just Completed"
  # Split on semicolons for multiple items
  IFS=';' read -ra ITEMS <<< "$COMPLETED"
  for item in "${ITEMS[@]}"; do
    item=$(echo "$item" | xargs) # trim
    [[ -n "$item" ]] && echo "- ${item}"
  done
  echo ""
  echo "## Key Decisions"
  IFS=';' read -ra ITEMS <<< "$DECISIONS"
  for item in "${ITEMS[@]}"; do
    item=$(echo "$item" | xargs)
    [[ -n "$item" ]] && echo "- ${item}"
  done
  echo ""
  echo "## Blockers"
  echo "- ${BLOCKERS}"
  echo ""
  echo "## Next"
  IFS=';' read -ra ITEMS <<< "$NEXT"
  for item in "${ITEMS[@]}"; do
    item=$(echo "$item" | xargs)
    [[ -n "$item" ]] && echo "- ${item}"
  done
} > "$TMPFILE"

mv "$TMPFILE" "$CHECKPOINT_FILE"
