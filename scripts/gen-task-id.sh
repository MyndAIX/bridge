#!/bin/bash
# gen-task-id.sh — Generate a unique MyndAIX task correlation ID
# Format: MX-{timestamp}-{random4}
# Example: MX-20260322-a3f1
#
# This ID links: Notion card → bridge file → Discord thread → git branch
# Usage: task_id=$(~/.myndaix/bridge/scripts/gen-task-id.sh)

TIMESTAMP=$(date -u '+%Y%m%d')
RAND=$(openssl rand -hex 2)
echo "MX-${TIMESTAMP}-${RAND}"
