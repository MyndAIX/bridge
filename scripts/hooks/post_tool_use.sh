#!/bin/bash
# PostToolUse hook for Claude Code observability
# Logs when a tool has finished being used

set -euo pipefail

# Extract tool name from environment or use fallback
tool_name="${CLAUDE_TOOL_NAME:-${1:-unknown}}"

# Calculate duration if start time exists
duration_ms=0
start_file="/tmp/claude_tool_start_${tool_name}_$$"
if [ -f "$start_file" ]; then
    start_time=$(cat "$start_file" 2>/dev/null || echo "0")
    end_time=$(date +%s%3N)
    duration_ms=$((end_time - start_time))
    # Clean up start time file
    rm -f "$start_file" 2>/dev/null || true
fi

# Log the PostToolUse event
exec ~/.myndaix/bridge/scripts/hooks/log_event.sh "PostToolUse" "$tool_name" "$duration_ms"