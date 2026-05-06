#!/bin/bash
# SubagentStart hook for Claude Code observability
# Logs when a subagent is starting

set -euo pipefail

# Extract subagent type from environment or use fallback
subagent_type="${CLAUDE_SUBAGENT_TYPE:-${1:-Agent}}"

# Store start time for duration calculation (used by SubagentStop)
echo "$(date +%s%3N)" > "/tmp/claude_subagent_start_${subagent_type}_$$" 2>/dev/null || true

# Log the SubagentStart event
exec ~/.myndaix/bridge/scripts/hooks/log_event.sh "SubagentStart" "$subagent_type" "0"