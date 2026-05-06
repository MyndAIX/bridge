#!/bin/bash
# Common event logging function for Claude Code hooks
# Usage: log_event.sh <event_type> <tool_name> <duration_ms>

set -euo pipefail

# Function to determine which agent we are (Mini or Mack)
get_agent_name() {
    hostname=$(hostname)
    case "$hostname" in
        *mini*|*Mini*)
            echo "mini"
            ;;
        *mack*|*Mack*|*MacBook*)
            echo "mack"
            ;;
        *)
            # Default to mini if we can't determine
            echo "mini"
            ;;
    esac
}

# Get parameters
event_type="${1:-unknown}"
tool_name="${2:-unknown}"
duration_ms="${3:-0}"

# Generate timestamp in ISO 8601 format
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

# Get agent name
agent=$(get_agent_name)

# Create the JSON event
event_json=$(cat <<EOF
{"timestamp":"$timestamp","agent":"$agent","event_type":"$event_type","tool_name":"$tool_name","duration_ms":$duration_ms}
EOF
)

# Ensure state directory exists
mkdir -p ~/.myndaix/bridge/state/

# Append to events.jsonl (create if doesn't exist)
echo "$event_json" >> ~/.myndaix/bridge/state/events.jsonl

# Exit successfully
exit 0