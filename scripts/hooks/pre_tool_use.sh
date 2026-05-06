#!/bin/bash
# PreToolUse hook for Claude Code observability
# Logs when a tool is about to be used

set -euo pipefail

# Extract tool name from environment or use fallback
tool_name="${CLAUDE_TOOL_NAME:-${1:-unknown}}"

# Store start time for duration calculation (used by PostToolUse)
echo "$(date +%s%3N)" > "/tmp/claude_tool_start_${tool_name}_$$" 2>/dev/null || true

# Log the PreToolUse event
exec ~/.myndaix/bridge/scripts/hooks/log_event.sh "PreToolUse" "$tool_name" "0"