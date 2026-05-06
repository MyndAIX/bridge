#!/bin/bash
# create-task.sh — Create a fully traced MyndAIX task
# Generates a task with correlation ID, writes to bridge, posts to Discord, creates Notion card
#
# Usage: create-task.sh <to_agent> <subject> <objective> <scope> <done_criteria> [priority] [risk_level]
# Example: create-task.sh mini "Fix auth bug" "Fix the login timeout" "SupabaseAuthService.swift" "Login works without timeout" P1 high

set -euo pipefail

TO="${1:?Usage: create-task.sh <to> <subject> <objective> <scope> <done_criteria> [priority] [risk_level]}"
SUBJECT="${2:?Missing subject}"
OBJECTIVE="${3:?Missing objective}"
SCOPE="${4:?Missing scope}"
DONE_CRITERIA="${5:?Missing done_criteria}"
PRIORITY="${6:-P2 — Medium}"
RISK_LEVEL="${7:-low}"

BRIDGE_ROOT="$HOME/.myndaix/bridge"
TASK_ID=$("$BRIDGE_ROOT/scripts/gen-task-id.sh")
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
FILENAME="${TASK_ID}.md"
INBOX="$BRIDGE_ROOT/inbox/$TO"
DISCORD_WEBHOOK_TASKS=""

# Load Discord env
DISCORD_ENV="$HOME/.myndaix/discord/.env"
if [ -f "$DISCORD_ENV" ]; then
  DISCORD_WEBHOOK_TASKS=$(grep '^DISCORD_WEBHOOK_TASKS=' "$DISCORD_ENV" | cut -d= -f2-)
fi

mkdir -p "$INBOX"

# Write bridge file
cat > "$INBOX/$FILENAME" << TASKEOF
---
from: lobster
to: $TO
type: task
subject: $SUBJECT
task_id: $TASK_ID
objective: $OBJECTIVE
scope: $SCOPE
done_criteria: $DONE_CRITERIA
priority: $PRIORITY
risk_level: $RISK_LEVEL
tier: auto
date: $TIMESTAMP
---

# $SUBJECT

**Objective:** $OBJECTIVE

**Scope:** $SCOPE

**Done criteria:** $DONE_CRITERIA

**Task ID:** $TASK_ID — use this ID in your result file and any git branches.
TASKEOF

echo "Bridge task created: $INBOX/$FILENAME"

# Post to Discord #task-queue
if [ -n "$DISCORD_WEBHOOK_TASKS" ]; then
  # Escape for JSON
  ESCAPED_SUBJECT=$(echo "$SUBJECT" | sed 's/"/\\"/g')
  ESCAPED_OBJ=$(echo "$OBJECTIVE" | sed 's/"/\\"/g')

  DISCORD_CONTENT="📋 **New Task** [\`$TASK_ID\`]\n**To:** $TO | **Priority:** $PRIORITY | **Risk:** $RISK_LEVEL\n**Objective:** $ESCAPED_OBJ"

  curl -s -H "Content-Type: application/json" \
    -d "{\"content\": \"$DISCORD_CONTENT\"}" \
    "$DISCORD_WEBHOOK_TASKS" > /dev/null 2>&1 &

  echo "Discord notification sent to #task-queue"
fi

echo ""
echo "Task ID: $TASK_ID"
echo "Agent: $TO"
echo "File: $INBOX/$FILENAME"
