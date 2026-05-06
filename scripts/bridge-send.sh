#!/bin/bash
# Send a file to an agent's inbox on the Mini
# Usage: bridge-send.sh <agent> <file>
# Example: bridge-send.sh lobster /tmp/message.md
MINI="jefe@${MINI_LAN_IP:-}"
AGENT="${1:?Usage: bridge-send.sh <agent> <file>}"
FILE="${2:?Usage: bridge-send.sh <agent> <file>}"

scp -o ConnectTimeout=3 "$FILE" "$MINI:~/.myndaix/bridge/inbox/$AGENT/" 2>/dev/null
