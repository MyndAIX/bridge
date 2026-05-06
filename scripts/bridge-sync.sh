#!/usr/bin/env bash
# bridge-sync.sh — bidirectional bridge sync between MacBook and Mini
# Run on the MacBook. Syncs every 30 seconds.
#
# Usage: ./bridge-sync.sh
# Or install as LaunchAgent (see below)

set -euo pipefail

MINI_HOST="jefe@${MINI_LAN_IP:-}"
MINI_BRIDGE="~/.myndaix/bridge"
LOCAL_BRIDGE="$HOME/.myndaix/bridge"

# Ensure local bridge structure exists
mkdir -p "$LOCAL_BRIDGE/inbox/mack"
mkdir -p "$LOCAL_BRIDGE/inbox/lobster"
mkdir -p "$LOCAL_BRIDGE/inbox/antman"
mkdir -p "$LOCAL_BRIDGE/inbox/kilabz"
mkdir -p "$LOCAL_BRIDGE/processed"

while true; do
    # Pull: Mini inboxes → MacBook (messages TO mack land locally)
    rsync -az --ignore-existing \
        "$MINI_HOST:$MINI_BRIDGE/inbox/mack/" \
        "$LOCAL_BRIDGE/inbox/mack/" 2>/dev/null || true

    # Push: MacBook outbox → Mini inboxes (messages FROM mack go to Mini)
    # Mack writes to local inbox/lobster/, sync pushes to Mini
    rsync -az --remove-source-files \
        "$LOCAL_BRIDGE/inbox/lobster/" \
        "$MINI_HOST:$MINI_BRIDGE/inbox/lobster/" 2>/dev/null || true

    rsync -az --remove-source-files \
        "$LOCAL_BRIDGE/inbox/antman/" \
        "$MINI_HOST:$MINI_BRIDGE/inbox/antman/" 2>/dev/null || true

    rsync -az --remove-source-files \
        "$LOCAL_BRIDGE/inbox/kilabz/" \
        "$MINI_HOST:$MINI_BRIDGE/inbox/kilabz/" 2>/dev/null || true

    # Sync processed (so Mack can see archived messages)
    rsync -az --ignore-existing \
        "$MINI_HOST:$MINI_BRIDGE/processed/" \
        "$LOCAL_BRIDGE/processed/" 2>/dev/null || true

    sleep 30
done
