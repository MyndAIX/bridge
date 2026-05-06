#!/bin/bash
# inbox-dispatcher.sh — Event-driven dispatcher for all agent watchers
# Uses fswatch to monitor inboxes and immediately trigger watchers
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

LOG="$HOME/.myndaix/bridge/watchers/dispatcher.log"
LOCKDIR="$HOME/.myndaix/bridge/locks/dispatcher.lock"
BRIDGE="$HOME/.myndaix/bridge"

log() {
  echo "[$(date "+%Y-%m-%d %H:%M:%S")] [dispatcher] $*" >> "$LOG"
}

# Prevent double-start
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$LOCKDIR/pid" ]; then
    OLD_PID=$(cat "$LOCKDIR/pid")
    if kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Dispatcher already running (PID $OLD_PID)"
      exit 0
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR"
  fi
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

log "Dispatcher started (PID $$)"

# Agent inbox -> watcher mapping
get_watcher() {
  case "$1" in
    mini)    echo "$BRIDGE/watchers/mini-watcher.sh" ;;
    antman)  echo "$BRIDGE/watchers/antman-watcher.sh" ;;
    kilabz)  echo "$BRIDGE/watchers/kilabz-watcher.sh" ;;
    recon)   echo "$BRIDGE/watchers/recon-watcher.sh" ;;
    smoke)   echo "$BRIDGE/watchers/smoke-watcher.sh" ;;
    *)       echo "" ;;
  esac
}

AGENTS="mini antman kilabz recon smoke"
WATCH_PATHS=""
for agent in $AGENTS; do
  inbox="$BRIDGE/inbox/$agent"
  mkdir -p "$inbox"
  WATCH_PATHS="$WATCH_PATHS $inbox"
  log "Watching: $inbox"
done

# Track last trigger per agent (debounce file)
DEBOUNCE_DIR="$BRIDGE/locks/debounce"
mkdir -p "$DEBOUNCE_DIR"

log "Starting fswatch on: $WATCH_PATHS"

fswatch -0 --event Created --event MovedTo --event Renamed $WATCH_PATHS | while IFS= read -r -d "" event_path; do
  # Only react to .md files; skip .tmp and Syncthing intermediaries
  case "$event_path" in
    *.tmp|*~syncthing~*|*.syncthing.*) continue ;;
    *.md) ;;
    *) continue ;;
  esac
  
  # Determine which agent
  AGENT=""
  for a in $AGENTS; do
    case "$event_path" in
      */inbox/$a/*) AGENT="$a"; break ;;
    esac
  done
  
  [ -z "$AGENT" ] && continue

  FILENAME=$(basename "$event_path")
  WATCHER=$(get_watcher "$AGENT")
  [ -z "$WATCHER" ] && continue

  # Debounce: per-file dedup (same file wont trigger twice)
  DEDUP_FILE="$DEBOUNCE_DIR/${AGENT}-files"
  DEDUP_KEY="${AGENT}:${FILENAME}"
  if grep -qF "$DEDUP_KEY" "$DEDUP_FILE" 2>/dev/null; then
    log "Dedup skip: $FILENAME (already dispatched to $AGENT)"
    continue
  fi
  echo "$DEDUP_KEY" >> "$DEDUP_FILE"
  tail -n 50 "$DEDUP_FILE" > "$DEDUP_FILE.tmp" 2>/dev/null && mv "$DEDUP_FILE.tmp" "$DEDUP_FILE"

  log "Event: $FILENAME -> $AGENT (triggering $(basename $WATCHER))"
  # Run watcher in background
  ("$WATCHER" >> "$LOG" 2>&1) &
done
