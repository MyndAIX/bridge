#!/bin/bash
# One-shot bridge pull: Mini → MacBook
# Runs at Claude Code session start on MacBook
MINI="jefe@${MINI_LAN_IP:-}"
REMOTE_INBOX="$MINI:~/.myndaix/bridge/inbox/mack/"
LOCAL_INBOX="$HOME/.myndaix/bridge/inbox/mack/"

mkdir -p "$LOCAL_INBOX"

# Pull new messages (don't overwrite existing), 3s timeout
rsync -az --timeout=3 --ignore-existing "$REMOTE_INBOX" "$LOCAL_INBOX" 2>/dev/null

# Always exit 0 so session starts even if Mini is unreachable
exit 0
