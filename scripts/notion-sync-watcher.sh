#!/usr/bin/env bash
# notion-sync-watcher.sh — Poll processed/ for new result files and sync to Notion.
# Runs as a LaunchAgent, polling every 60 seconds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/notion-sync.py"
LOG_DIR="$HOME/.myndaix/bridge/logs"
LOG_FILE="$LOG_DIR/notion-sync.log"
HEARTBEAT_FILE="$HOME/.myndaix/bridge/state/notion-sync.heartbeat"
PYTHON="/usr/bin/python3"

mkdir -p "$LOG_DIR" "$(dirname "$HEARTBEAT_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "notion-sync-watcher started (PID $$)"

while true; do
    if output=$("$PYTHON" "$SYNC_SCRIPT" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi
    # Heartbeat: cheap liveness signal; consumers read this, not the log
    echo "$(date '+%Y-%m-%d %H:%M:%S') exit=$exit_code" > "$HEARTBEAT_FILE"
    # Only log full cycle when interesting (errors or work happened)
    if [[ $exit_code -ne 0 || -n "$output" ]]; then
        log "Running sync cycle..."
        if [[ -n "$output" ]]; then
            printf '%s\n' "$output" >> "$LOG_FILE"
        fi
        if [[ $exit_code -eq 0 ]]; then
            log "Sync cycle complete."
        else
            log "ERROR: Sync script exited with code $exit_code"
        fi
    fi
    sleep 60
done
