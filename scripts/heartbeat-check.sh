#!/bin/bash
# heartbeat-check.sh — Lightweight readiness check
# Only alerts when an agent has stuck tasks AND no recent heartbeat
set -uo pipefail
export HOME="${HOME:-/Users/$(whoami)}"
STATE="$HOME/.myndaix/bridge/state"
ALERT_WEBHOOK="$(grep DISCORD_WEBHOOK_ALERTS $HOME/.myndaix/discord/.env 2>/dev/null | cut -d= -f2-)"
NOW=$(date +%s)
ISSUES=0

for AGENT in mini antman kilabz recon; do
  INBOX="$HOME/.myndaix/bridge/inbox/$AGENT"
  HB="$STATE/${AGENT}-heartbeat.json"
  
  # Count inbox files
  INBOX_COUNT=0
  for f in "$INBOX"/*.md; do
    [ -f "$f" ] || continue
    INBOX_COUNT=$((INBOX_COUNT + 1))
  done
  
  # Skip if inbox empty — nothing to worry about
  [ "$INBOX_COUNT" -eq 0 ] && continue
  
  # Check oldest file age
  OLDEST_AGE=0
  for f in "$INBOX"/*.md; do
    [ -f "$f" ] || continue
    FAGE=$(( NOW - $(stat -f %m "$f" 2>/dev/null || echo $NOW) ))
    [ "$FAGE" -gt "$OLDEST_AGE" ] && OLDEST_AGE=$FAGE
  done
  
  # Only alert if task stuck > 30 min
  [ "$OLDEST_AGE" -lt 1800 ] && continue
  
  # Check heartbeat — has agent processed anything recently?
  if [ -f "$HB" ]; then
    LAST_BEAT=$(python3 -c "import json; print(json.load(open('$HB')).get('last_beat',''))" 2>/dev/null)
    if [ -n "$LAST_BEAT" ]; then
      BEAT_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAST_BEAT" +%s 2>/dev/null || echo 0)
      BEAT_AGE=$(( NOW - BEAT_EPOCH ))
      # If heartbeat recent (< 30 min), agent is working — just slow
      [ "$BEAT_AGE" -lt 1800 ] && continue
    fi
  fi
  
  # Agent has stuck tasks AND no recent heartbeat — alert
  MINS=$((OLDEST_AGE / 60))
  MSG="$AGENT: $INBOX_COUNT task(s) stuck for ${MINS}m with no heartbeat"
  if [ -n "$ALERT_WEBHOOK" ]; then
    curl -s -H 'Content-Type: application/json' \
      -d "{\"content\": \"⚠️ $MSG\"}" \
      "$ALERT_WEBHOOK" > /dev/null 2>&1
  fi
  ISSUES=$((ISSUES + 1))
done
