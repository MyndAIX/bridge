#!/bin/bash
set -euo pipefail
WATCHERS_DIR="$HOME/.myndaix/bridge/watchers"
LOGFILE="$WATCHERS_DIR/watcher.log"
OPENCLAW="/opt/homebrew/bin/openclaw"
mkdir -p "$WATCHERS_DIR"

ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[$ts] inbox-trigger fired" >> "$LOGFILE"

if "$OPENCLAW" system event --mode now --text "[Bridge] New inbox message" 2>>"$LOGFILE"; then
  echo "[$ts] trigger method: openclaw system event --mode now (success)" >> "$LOGFILE"
else
  echo "[$ts] trigger method: openclaw system event FAILED (exit $?)" >> "$LOGFILE"
fi
