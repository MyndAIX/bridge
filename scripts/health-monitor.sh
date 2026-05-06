#!/bin/bash
# health-monitor.sh — MyndAIX Agent Health Monitor
# Checks all agents, restarts what's down, alerts on failures
# Run via LaunchAgent every 5 minutes

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

LOG="$HOME/.myndaix/bridge/watchers/health-monitor.log"
ALERT_WEBHOOK="$(grep DISCORD_WEBHOOK_ALERTS $HOME/.myndaix/discord/.env 2>/dev/null | cut -d= -f2-)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [health] $*" >> "$LOG"; }
alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$ALERT_WEBHOOK" ]; then
    curl -s -H 'Content-Type: application/json'       -d "{\"content\": \"🚨 **Agent Health Alert:** $msg\"}"       "$ALERT_WEBHOOK" > /dev/null 2>&1
  fi
}

ISSUES=0

# Check OpenClaw gateway
if ! pgrep -f 'openclaw-gateway' > /dev/null 2>&1; then
  log "OpenClaw gateway is DOWN — restarting"
  # LaunchAgent should auto-restart, but force it
  launchctl kickstart -k gui/$(id -u)/com.openclaw.gateway 2>/dev/null || true
  sleep 5
  if pgrep -f 'openclaw-gateway' > /dev/null 2>&1; then
    log "OpenClaw gateway restarted successfully"
  else
    alert "Lobster (OpenClaw gateway) is DOWN and failed to restart"
    ISSUES=$((ISSUES + 1))
  fi
fi

# Check OpenClaw gateway responsiveness (RPC probe, not log age)
NOW=$(date +%s)
GW_PROBE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://127.0.0.1:18789/ 2>/dev/null || echo 000)
if [ "$GW_PROBE" = "000" ]; then
  alert "Lobster gateway not responding (RPC probe failed)"
  ISSUES=$((ISSUES + 1))
fi

# Check proxy chain
PROXY_3456=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://localhost:3456/v1/models 2>/dev/null || echo 000)
PROXY_3457=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://localhost:3457/v1/models 2>/dev/null || echo 000)

if [ "$PROXY_3456" != "200" ]; then
  log "claude-max-api (port 3456) returning $PROXY_3456 — restarting"
  pkill -f 'claude-max-api-proxy/dist/server/standalone' 2>/dev/null
  sleep 2
  nohup node /opt/homebrew/lib/node_modules/claude-max-api-proxy/dist/server/standalone.js >> "$HOME/.openclaw/logs/claude-max-api.err.log" 2>&1 &
  sleep 3
  PROXY_3456=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://localhost:3456/v1/models 2>/dev/null || echo 000)
  if [ "$PROXY_3456" = "200" ]; then
    log "claude-max-api restarted successfully"
  else
    alert "Claude proxy (port 3456) is DOWN — Lobster cannot reach Claude API"
    ISSUES=$((ISSUES + 1))
  fi
fi

if [ "$PROXY_3457" != "200" ]; then
  log "proxy-fix (port 3457) returning $PROXY_3457 — restarting"
  pkill -f 'proxy-fix.js' 2>/dev/null
  sleep 2
  nohup node "$HOME/proxy-fix.js" >> /tmp/proxy-fix.log 2>&1 &
  sleep 2
  PROXY_3457=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://localhost:3457/v1/models 2>/dev/null || echo 000)
  if [ "$PROXY_3457" = "200" ]; then
    log "proxy-fix restarted successfully"
  else
    alert "Proxy-fix (port 3457) is DOWN"
    ISSUES=$((ISSUES + 1))
  fi
fi

# Check bridge forwarder
if ! pgrep -f 'bridge-forwarder.js' > /dev/null 2>&1; then
  log "Bridge forwarder is DOWN — restarting"
  nohup node "$HOME/.myndaix/discord/bridge-forwarder.js" >> "$HOME/.myndaix/discord/forwarder.log" 2>&1 &
  sleep 2
  if pgrep -f 'bridge-forwarder.js' > /dev/null 2>&1; then
    log "Bridge forwarder restarted"
  else
    alert "Bridge forwarder failed to restart — Discord relay offline"
    ISSUES=$((ISSUES + 1))
  fi
fi

# Check dashboard updater
if ! pgrep -f 'dashboard-updater.js' > /dev/null 2>&1; then
  log "Dashboard updater is DOWN — restarting"
  nohup node "$HOME/.myndaix/discord/dashboard-updater.js" >> "$HOME/.myndaix/discord/dashboard.log" 2>&1 &
  log "Dashboard updater restarted"
fi

# Check inbox dispatcher
if ! pgrep -f 'inbox-dispatcher.sh' > /dev/null 2>&1; then
  log "Inbox dispatcher is DOWN — restarting"
  rm -rf "$HOME/.myndaix/bridge/locks/dispatcher.lock"
  nohup bash "$HOME/.myndaix/bridge/scripts/inbox-dispatcher.sh" >> "$HOME/.myndaix/bridge/watchers/dispatcher.log" 2>&1 &
  sleep 2
  if pgrep -f 'inbox-dispatcher.sh' > /dev/null 2>&1; then
    log "Inbox dispatcher restarted"
  else
    alert "Inbox dispatcher failed to restart — agents won't pick up tasks"
    ISSUES=$((ISSUES + 1))
  fi
fi

# Check for stuck tasks (in inbox > 30 min)
for agent in mini antman kilabz recon; do
  INBOX="$HOME/.myndaix/bridge/inbox/$agent"
  for f in "$INBOX"/*.md; do
    [ -f "$f" ] || continue
    FILE_AGE=$(( NOW - $(stat -f %m "$f" 2>/dev/null || echo $NOW) ))
    if [ "$FILE_AGE" -gt 1800 ]; then
      FNAME=$(basename "$f")
      alert "$agent has stuck task: $FNAME (${FILE_AGE}s old)"
      ISSUES=$((ISSUES + 1))
    fi
  done
done

# Summary
if [ "$ISSUES" -eq 0 ]; then
  log "All systems healthy"
else
  log "Health check found $ISSUES issue(s)"
fi
