#!/bin/bash
# wait-for-response.sh — Wait for a new message in an inbox
# Usage: wait-for-response.sh <inbox_path> <timeout_seconds> [after_timestamp]
# Returns the path of the new file, or empty if timeout
# Example: wait-for-response.sh ~/.myndaix/bridge/inbox/mack 120

set -uo pipefail

INBOX="${1:?Usage: wait-for-response.sh <inbox_path> <timeout_seconds> [after_timestamp]}"
TIMEOUT="${2:-120}"
AFTER="${3:-$(date +%s)}"

ELAPSED=0
INTERVAL=5

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  # Check for any .md files newer than our start time
  for f in "$INBOX"/*.md; do
    [ -f "$f" ] || continue
    FILE_TIME=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)
    if [ "$FILE_TIME" -gt "$AFTER" ]; then
      echo "$f"
      exit 0
    fi
  done

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

exit 1
