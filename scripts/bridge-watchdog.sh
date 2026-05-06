#!/bin/bash
# bridge-watchdog.sh — Stateless, idempotent bridge health checker
# Runs on 5-min LaunchAgent cycle. Separate from health-monitor.sh (infra/services).
# Checks: dispatcher alive, stale locks, stuck inbox files.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

BRIDGE="$HOME/.myndaix/bridge"
LOG="$BRIDGE/watchers/bridge-watchdog.log"
LOCK_DIR="$BRIDGE/locks"
STALE_LOCK_SECS=1800    # 30 minutes
STUCK_INBOX_SECS=1800   # 30 minutes
NOW=$(date +%s)
ISSUES=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $*" >> "$LOG"
}

alert() {
  local msg="$1"
  log "ALERT: $msg"
  # Best-effort Discord alert via openclaw
  if command -v openclaw >/dev/null 2>&1; then
    openclaw message send --channel discord -t "${DISCORD_COMMAND_CHANNEL:-}" \
      -m "🐕 **Bridge Watchdog:** $msg" --silent 2>/dev/null &
  fi
}

# ─── Rotate log if > 500KB ───
if [[ -f "$LOG" ]]; then
  LOG_SIZE=$(wc -c < "$LOG" | tr -d ' ')
  if (( LOG_SIZE > 512000 )); then
    mv "$LOG" "${LOG}.bak"
    log "Rotated log (was ${LOG_SIZE} bytes)"
  fi
fi

log "Watchdog run starting"

# ─── 1. Check dispatcher alive ───
if pgrep -f 'inbox-dispatcher.sh' > /dev/null 2>&1; then
  log "Dispatcher: alive"
else
  log "Dispatcher: DOWN — attempting restart"
  # Clean stale dispatcher lock before restart
  rm -rf "$LOCK_DIR/dispatcher.lock"
  nohup bash "$BRIDGE/scripts/inbox-dispatcher.sh" >> "$BRIDGE/watchers/dispatcher.log" 2>&1 &
  sleep 3
  if pgrep -f 'inbox-dispatcher.sh' > /dev/null 2>&1; then
    log "Dispatcher: restarted successfully"
  else
    alert "Dispatcher is DOWN and failed to restart"
    ISSUES=$((ISSUES + 1))
  fi
fi

# ─── 2. Check stale locks (>30 min) ───
for lockdir in "$LOCK_DIR"/*.lock; do
  [[ -d "$lockdir" ]] || continue
  LOCK_NAME=$(basename "$lockdir")

  # Check if PID is still alive
  if [[ -f "$lockdir/pid" ]]; then
    LOCK_PID=$(cat "$lockdir/pid" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
      # Process alive — check age via start_time if available
      if [[ -f "$lockdir/start_time" ]]; then
        LOCK_START=$(cat "$lockdir/start_time" 2>/dev/null || echo "$NOW")
        LOCK_AGE=$((NOW - LOCK_START))
        if (( LOCK_AGE > STALE_LOCK_SECS )); then
          alert "Stale lock: $LOCK_NAME held by PID $LOCK_PID for ${LOCK_AGE}s — killing"
          kill "$LOCK_PID" 2>/dev/null || true
          sleep 2
          kill -9 "$LOCK_PID" 2>/dev/null || true
          rm -rf "$lockdir"
          ISSUES=$((ISSUES + 1))
        else
          log "Lock $LOCK_NAME: active (PID $LOCK_PID, ${LOCK_AGE}s)"
        fi
      else
        log "Lock $LOCK_NAME: active (PID $LOCK_PID, no start_time)"
      fi
    else
      # PID dead — orphaned lock
      log "Orphaned lock: $LOCK_NAME (PID ${LOCK_PID:-unknown} not running) — removing"
      rm -rf "$lockdir"
      ISSUES=$((ISSUES + 1))
    fi
  else
    # No PID file — check directory age via stat
    LOCK_MTIME=$(stat -f %m "$lockdir" 2>/dev/null || echo "$NOW")
    LOCK_AGE=$((NOW - LOCK_MTIME))
    if (( LOCK_AGE > STALE_LOCK_SECS )); then
      log "Stale lock (no pid): $LOCK_NAME (${LOCK_AGE}s) — removing"
      rm -rf "$lockdir"
      ISSUES=$((ISSUES + 1))
    fi
  fi
done

# ─── 3. Check stuck inbox files ───
AGENTS="mini antman kilabz recon harley"
for agent in $AGENTS; do
  INBOX="$BRIDGE/inbox/$agent"
  [[ -d "$INBOX" ]] || continue
  for f in "$INBOX"/*.md; do
    [[ -f "$f" ]] || continue
    # Skip temp files
    case "$f" in
      *.tmp|*~syncthing~*|*.syncthing.*) continue ;;
    esac
    FILE_MTIME=$(stat -f %m "$f" 2>/dev/null || echo "$NOW")
    FILE_AGE=$((NOW - FILE_MTIME))
    if (( FILE_AGE > STUCK_INBOX_SECS )); then
      FNAME=$(basename "$f")
      alert "$agent inbox stuck: $FNAME (${FILE_AGE}s old)"
      ISSUES=$((ISSUES + 1))
    fi
  done
done

# ─── Summary ───
if (( ISSUES == 0 )); then
  log "All clear — no issues found"
else
  log "Found $ISSUES issue(s)"
fi
