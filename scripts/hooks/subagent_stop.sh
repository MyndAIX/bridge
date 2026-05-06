#!/bin/bash
# SubagentStop hook for Claude Code observability
# Logs when a subagent has stopped

set -euo pipefail

# Extract subagent type from environment or use fallback
subagent_type="${CLAUDE_SUBAGENT_TYPE:-${1:-Agent}}"

# Calculate duration if start time exists
duration_ms=0
start_file="/tmp/claude_subagent_start_${subagent_type}_$$"
if [ -f "$start_file" ]; then
    start_time=$(cat "$start_file" 2>/dev/null || echo "0")
    end_time=$(date +%s%3N)
    duration_ms=$((end_time - start_time))
    # Clean up start time file
    rm -f "$start_file" 2>/dev/null || true
fi

# Log the SubagentStop event
exec ~/.myndaix/bridge/scripts/hooks/log_event.sh "SubagentStop" "$subagent_type" "$duration_ms"