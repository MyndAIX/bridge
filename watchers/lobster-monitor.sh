#!/usr/bin/env bash
# lobster-monitor.sh — Monitors OpenClaw session health, auto-rotates before degradation
# LaunchAgent: ai.myndaix.lobster-monitor (every 5 min)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"

STATE_FILE="$HOME/.myndaix/bridge/state/lobster-session.json"
SESSIONS_DIR="$HOME/.openclaw/agents/main/sessions"
PLIST_LABEL="ai.openclaw.gateway"
PLIST_PATH="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
LOG="/tmp/lobster-monitor.log"
LOCK_DIR="/tmp/lobster-monitor.lock"
WEBHOOK_URL="${DISCORD_WEBHOOK_ALERTS:-}"
HOSTNAME=$(hostname -s)

# Thresholds
MAX_RSS_KB=614400          # 400 MB
MAX_CPU_SECONDS=1800       # 30 minutes
MAX_UPTIME_SECONDS=43200   # 12 hours
MAX_SESSION_KB=200         # 200 KB session file
COOLDOWN_SECONDS=600       # 10 min between rotations

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# --- Lockfile ---
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi

# --- Discord alert ---
alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [[ -n "$WEBHOOK_URL" ]]; then
    curl -sf -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"content\":\"$msg\",\"allowed_mentions\":{\"parse\":[]}}" \
      --max-time 5 >/dev/null 2>&1 || true
  fi
}

# --- Read state ---
read_state() {
  if [[ -f "$STATE_FILE" ]]; then
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('$1',''))" "$STATE_FILE" 2>/dev/null || echo ""
  fi
}

# --- Write state (atomic) ---
write_state() {
  local pid="$1" rss="$2" cpu_sec="$3" uptime_sec="$4" session_kb="$5" status="$6"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local last_rotation
  last_rotation=$(read_state last_rotation)
  local rotations_today
  rotations_today=$(read_state rotations_today)
  [[ -z "$rotations_today" ]] && rotations_today=0

  mkdir -p "$(dirname "$STATE_FILE")"
  python3 -c "
import json
d = {
    'pid': $pid,
    'rss_mb': round($rss / 1024, 1),
    'cpu_minutes': round($cpu_sec / 60, 1),
    'uptime_hours': round($uptime_sec / 3600, 1),
    'session_file_kb': $session_kb,
    'last_check': '$now',
    'last_rotation': '${last_rotation:-never}',
    'rotations_today': $rotations_today,
    'status': '$status'
}
with open('${STATE_FILE}.tmp', 'w') as f:
    json.dump(d, f, indent=2)
"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# --- Parse etime to seconds ---
etime_to_seconds() {
  local etime="$1"
  python3 -c "
import sys, re
e = sys.argv[1].strip()
parts = re.split('[:-]', e)
parts = [int(p) for p in parts]
if len(parts) == 4:  # D-HH:MM:SS
    print(parts[0]*86400 + parts[1]*3600 + parts[2]*60 + parts[3])
elif len(parts) == 3:  # HH:MM:SS
    print(parts[0]*3600 + parts[1]*60 + parts[2])
elif len(parts) == 2:  # MM:SS
    print(parts[0]*60 + parts[1])
else:
    print(0)
" "$etime"
}

# --- Parse cputime to seconds ---
cputime_to_seconds() {
  local cputime="$1"
  python3 -c "
import sys
t = sys.argv[1].strip()
parts = t.split(':')
if len(parts) == 3:
    print(int(parts[0])*3600 + int(parts[1])*60 + float(parts[2]))
elif len(parts) == 2:
    print(int(parts[0])*60 + float(parts[1]))
else:
    print(0)
" "$cputime"
}

# --- Rotate OpenClaw ---
rotate() {
  local reason="$1"
  local last_rotation
  last_rotation=$(read_state last_rotation)

  # Cooldown check
  if [[ -n "$last_rotation" && "$last_rotation" != "never" ]]; then
    local seconds_since
    seconds_since=$(python3 -c "
from datetime import datetime, timezone
try:
    last = '$last_rotation'.replace('Z', '+00:00')
    last_dt = datetime.fromisoformat(last)
    diff = (datetime.now(timezone.utc) - last_dt).total_seconds()
    print(int(diff))
except: print(999999)
" 2>/dev/null || echo 999999)
    if (( seconds_since < COOLDOWN_SECONDS )); then
      log "COOLDOWN: rotation needed ($reason) but within ${COOLDOWN_SECONDS}s window — skipping"
      alert "⏳ **$HOSTNAME**: Lobster rotation needed ($reason) but in cooldown — skipping"
      return
    fi
  fi

  log "ROTATING: $reason"
  alert "🔄 **$HOSTNAME**: Rotating Lobster — $reason"

  # Reset active session file
  for f in "$SESSIONS_DIR"/*.jsonl; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.reset.* ]] && continue
    local size
    size=$(wc -c < "$f" | tr -d ' ')
    if (( size > 1000 )); then
      mv "$f" "${f}.reset.$(date -u +%Y-%m-%dT%H-%M-%SZ)"
      rm -f "${f}.lock"
      log "Reset session: $(basename "$f") (${size} bytes)"
    fi
  done

  # Clean old .reset files (keep last 5)
  ls -t "$SESSIONS_DIR"/*.reset.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  # Rotate via launchd
  local uid
  uid=$(id -u)
  launchctl bootout "gui/$uid/$PLIST_LABEL" 2>/dev/null || true
  sleep 3
  launchctl bootstrap "gui/$uid" "$PLIST_PATH" 2>/dev/null || true

  # Update state
  local rotations
  rotations=$(read_state rotations_today)
  [[ -z "$rotations" ]] && rotations=0
  rotations=$((rotations + 1))

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  python3 -c "
import json
d = {'pid': 0, 'rss_mb': 0, 'cpu_minutes': 0, 'uptime_hours': 0, 'session_file_kb': 0,
     'last_check': '$now', 'last_rotation': '$now', 'rotations_today': $rotations, 'status': 'rotated'}
with open('${STATE_FILE}.tmp', 'w') as f:
    json.dump(d, f, indent=2)
"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"

  log "Rotation complete. Rotations today: $rotations"
  alert "✅ **$HOSTNAME**: Lobster rotation complete (rotations today: $rotations)"
}

# --- Main ---

# Find OpenClaw gateway PID
PID=$(pgrep -f "openclaw-gateway" | head -1 || echo "")

if [[ -z "$PID" ]]; then
  log "OpenClaw gateway not running"
  alert "❌ **$HOSTNAME**: Lobster (OpenClaw gateway) is NOT running"
  write_state 0 0 0 0 0 "dead"
  exit 0
fi

# Get process stats
STATS=$(ps -o rss=,cputime=,etime= -p "$PID" 2>/dev/null | head -1)
if [[ -z "$STATS" ]]; then
  log "Could not read process stats for PID $PID"
  write_state "$PID" 0 0 0 0 "unknown"
  exit 0
fi

RSS=$(echo "$STATS" | awk '{print $1}')
CPUTIME=$(echo "$STATS" | awk '{print $2}')
ETIME=$(echo "$STATS" | awk '{print $3}')

CPU_SEC=$(cputime_to_seconds "$CPUTIME")
UPTIME_SEC=$(etime_to_seconds "$ETIME")

# Get session file size
SESSION_KB=0
for f in "$SESSIONS_DIR"/*.jsonl; do
  [[ -f "$f" ]] || continue
  [[ "$f" == *.reset.* ]] && continue
  [[ "$f" == *.lock ]] && continue
  local_size=$(wc -c < "$f" | tr -d ' ')
  local_kb=$((local_size / 1024))
  if (( local_kb > SESSION_KB )); then
    SESSION_KB=$local_kb
  fi
done

# Write state
write_state "$PID" "$RSS" "${CPU_SEC%.*}" "${UPTIME_SEC%.*}" "$SESSION_KB" "healthy"

log "PID=$PID RSS=${RSS}KB CPU=${CPUTIME} UPTIME=${ETIME} SESSION=${SESSION_KB}KB"

# Check thresholds
if (( RSS > MAX_RSS_KB )); then
  rotate "RSS ${RSS}KB > ${MAX_RSS_KB}KB limit ($(( RSS / 1024 ))MB)"
elif (( ${CPU_SEC%.*} > MAX_CPU_SECONDS )); then
  rotate "CPU time ${CPUTIME} > $(( MAX_CPU_SECONDS / 60 ))min limit"
elif (( ${UPTIME_SEC%.*} > MAX_UPTIME_SECONDS )); then
  rotate "Uptime ${ETIME} > $(( MAX_UPTIME_SECONDS / 3600 ))h limit"
elif (( SESSION_KB > MAX_SESSION_KB )); then
  rotate "Session file ${SESSION_KB}KB > ${MAX_SESSION_KB}KB limit"
fi

# ═══════════════════════════════════════════════════════
# Bridge Health Check — all agents, every cycle
# ═══════════════════════════════════════════════════════

HEARTBEAT_DIR="$HOME/.myndaix/bridge/state"
INBOX_ROOT="$HOME/.myndaix/bridge/inbox"
STALE_THRESHOLD=7200  # 2 hours without heartbeat = stale
BACKLOG_THRESHOLD=5   # 5+ queued tasks = alert
AGENTS="mini antman kilabz recon mack oracle"

bridge_alerts=""

for agent in $AGENTS; do
  hb_file="$HEARTBEAT_DIR/${agent}-heartbeat.json"

  # Check heartbeat freshness
  if [[ -f "$hb_file" ]]; then
    last_beat=$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(open(sys.argv[1]))
    last = d.get('last_beat', '')
    if last:
        dt = datetime.fromisoformat(last.replace('Z', '+00:00'))
        diff = (datetime.now(timezone.utc) - dt).total_seconds()
        print(int(diff))
    else:
        print(999999)
except: print(999999)
" "$hb_file" 2>/dev/null || echo 999999)

    if (( last_beat > STALE_THRESHOLD )); then
      hours=$(( last_beat / 3600 ))
      # Check inbox backlog before alerting — idle agents are fine
      inbox_count=$(ls "$HOME/.myndaix/bridge/inbox/${agent}" 2>/dev/null | wc -l | tr -d " ")
      # Alert if: queued work AND stale, OR very stale (>24h regardless)
      if (( inbox_count > 0 )) || (( hours > 24 )); then
        bridge_alerts="${bridge_alerts}⚠️ ${agent}: no heartbeat in ${hours}h (queued=${inbox_count})\n"
      fi
    fi

    # Check last result
    last_result=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('last_result', ''))
except: print('')
" "$hb_file" 2>/dev/null || echo "")

    if [[ "$last_result" == "FAILED" || "$last_result" == "TIMEOUT" ]]; then
      bridge_alerts="${bridge_alerts}⚠️ ${agent}: last task ${last_result}\n"
    fi
  fi

  # Check inbox backlog
  inbox_dir="$INBOX_ROOT/${agent}"
  if [[ -d "$inbox_dir" ]]; then
    backlog=$(find "$inbox_dir" -name '*.md' -not -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    if (( backlog > BACKLOG_THRESHOLD )); then
      bridge_alerts="${bridge_alerts}⚠️ ${agent}: ${backlog} tasks queued\n"
    fi
  fi
done

# Only alert if something is wrong — silent when healthy
# Dedup: only alert if content changed or 1h since last
if [[ -n "$bridge_alerts" ]]; then
  # Hash ignores changing hour numbers — only structure matters
  ALERT_HASH=$(echo "$bridge_alerts" | sed -E "s/[0-9]+h/Nh/g; s/queued=[0-9]+/queued=N/g" | md5)
  ALERT_STATE="$HOME/.myndaix/bridge/state/bridge-health-last-alert.txt"
  LAST_HASH=""; LAST_TIME=0
  if [[ -f "$ALERT_STATE" ]]; then
    LAST_HASH=$(head -1 "$ALERT_STATE" 2>/dev/null || echo "")
    LAST_TIME=$(sed -n "2p" "$ALERT_STATE" 2>/dev/null || echo 0)
  fi
  NOW=$(date +%s); ELAPSED=$((NOW - LAST_TIME))
  if [[ "$ALERT_HASH" != "$LAST_HASH" ]] || (( ELAPSED > 3600 )); then
    alert "🏥 **Bridge Health:**\n${bridge_alerts}"
    log "BRIDGE HEALTH ISSUES:\n${bridge_alerts}"
    echo "$ALERT_HASH" > "$ALERT_STATE"
    echo "$NOW" >> "$ALERT_STATE"
  else
    log "BRIDGE HEALTH: deduped (elapsed=${ELAPSED}s)"
  fi
fi
# ═══════════════════════════════════════════════════════
# Daily Digest — once per day at first check after 6 AM
# ═══════════════════════════════════════════════════════

DIGEST_STATE="$HEARTBEAT_DIR/daily-digest-last.txt"
TODAY=$(date '+%Y-%m-%d')
CURRENT_HOUR=$(date '+%H')
LAST_DIGEST=$(cat "$DIGEST_STATE" 2>/dev/null || echo "")

if [[ "$CURRENT_HOUR" -ge 23 && "$LAST_DIGEST" != "$TODAY" ]]; then
  # Generate daily digest — runs at 11 PM so Jefe catches issues before sleep
  DIGEST=$(python3 << 'PYDIGEST'
import json, os, glob
from datetime import datetime, timezone, timedelta

state_dir = os.path.expanduser("~/.myndaix/bridge/state")
cost_log = os.path.join(state_dir, "cost-log.jsonl")
today = datetime.now().strftime("%Y-%m-%d")
yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")

# Cost summary
total_cost = 0
by_agent = {}
task_count = 0
if os.path.exists(cost_log):
    for line in open(cost_log):
        try:
            e = json.loads(line.strip())
            if e.get("ts", "").startswith(yesterday):
                cost = e.get("cost_usd", 0)
                total_cost += cost
                agent = e.get("agent", "unknown")
                by_agent[agent] = by_agent.get(agent, 0) + cost
                task_count += 1
        except: pass

# Agent health
agents_healthy = 0
agents_total = 0
agent_issues = []
for hb in glob.glob(os.path.join(state_dir, "*-heartbeat.json")):
    agents_total += 1
    try:
        d = json.load(open(hb))
        last = d.get("last_beat", "")
        if last:
            dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
            age = (datetime.now(timezone.utc) - dt).total_seconds()
            if age < 14400:  # 4 hours
                agents_healthy += 1
            else:
                name = os.path.basename(hb).replace("-heartbeat.json", "")
                agent_issues.append(f"{name} (stale {int(age/3600)}h)")
    except: pass

# Lobster rotations
lobster_state = os.path.join(state_dir, "lobster-session.json")
rotations = 0
if os.path.exists(lobster_state):
    try:
        d = json.load(open(lobster_state))
        rotations = d.get("rotations_today", 0)
    except: pass

# Build digest
lines = []
lines.append(f"📊 **MyndAIX Daily — {yesterday}**")
lines.append(f"├── Tasks: {task_count} completed")
if total_cost > 0:
    cost_parts = ", ".join(f"{a} ${c:.2f}" for a, c in sorted(by_agent.items(), key=lambda x: -x[1]))
    lines.append(f"├── Cost: ${total_cost:.2f} ({cost_parts})")
else:
    lines.append(f"├── Cost: no data yet")
lines.append(f"├── Agents: {agents_healthy}/{agents_total} healthy")
if agent_issues:
    lines.append(f"│   └── Issues: {', '.join(agent_issues)}")
if rotations > 0:
    lines.append(f"├── Lobster rotations: {rotations}")
lines.append(f"└── Report generated {datetime.now().strftime('%H:%M')}")

print("\n".join(lines))
PYDIGEST
)

  # Append systems analysis (Layer 1)
  ANALYSIS_SCRIPT="$HOME/.myndaix/bridge/scripts/systems-analysis.sh"
  if [[ -x "$ANALYSIS_SCRIPT" ]]; then
    SYSTEMS_REPORT=$(bash "$ANALYSIS_SCRIPT" 2>/dev/null || echo "Systems analysis failed")
    DIGEST="${DIGEST}\n\n${SYSTEMS_REPORT}"

    # Detect escalation signal — flag in digest and log
    if echo "$SYSTEMS_REPORT" | grep -q 'ESCALATION_RECOMMENDED'; then
      log "ESCALATION: systems analysis recommends external architecture review"
      DIGEST="${DIGEST}\n\n\U0001F6A8 **Action required:** External architecture review recommended. Run Perplexity audit or get fresh-eyes analysis."
    fi
  fi

  if [[ -n "$DIGEST" ]]; then
    alert "$DIGEST"
    log "DAILY DIGEST + SYSTEMS ANALYSIS SENT"
    echo "$TODAY" > "$DIGEST_STATE"
  fi
fi

# ═══════════════════════════════════════════════════════

# ======================================================
# Loop Detector — Auto-wipe Lobster session if stuck repeating
# ======================================================
DISCORD_CHANNEL="${DISCORD_LOOP_CHANNEL:-}"
SESSIONS_JSON="$HOME/.openclaw/agents/main/sessions/sessions.json"
# DISCORD_BOT_TOKEN sourced from ~/.myndaix/.secrets at the top of this script.
# Loop detection is best-effort; if either is unset, skip silently.
BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"

LAST_MSGS=""
if [[ -n "$DISCORD_CHANNEL" && -n "$BOT_TOKEN" ]]; then
  LAST_MSGS=$(curl -s --max-time 10 \
    "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages?limit=6" \
    -H "Authorization: Bot $BOT_TOKEN" 2>/dev/null)
fi

if [[ -n "$LAST_MSGS" ]]; then
  export LOOP_MSGS="$LAST_MSGS"
  LOOP_DETECTED=$(python3 << 'LOOPCHECK'
import json, os
try:
    msgs = json.loads(os.environ.get("LOOP_MSGS","[]"))
    bot_msgs = [m["content"][:200] for m in msgs if m.get("author",{}).get("bot")]
    if len(bot_msgs) >= 2 and bot_msgs[0] == bot_msgs[1]:
        print("LOOP")
    else:
        print("OK")
except:
    print("ERROR")
LOOPCHECK
  )

  if [[ "$LOOP_DETECTED" == "LOOP" ]]; then
    log "LOOP DETECTED: Lobster repeating same message — auto-wiping session"
    python3 << 'WIPE'
import json, glob, os
sessions_path = os.path.expanduser("~/.openclaw/agents/main/sessions/sessions.json")
channel = "${DISCORD_COMMAND_CHANNEL:-}"
try:
    with open(sessions_path) as f:
        sessions = json.load(f)
    key = f"agent:main:discord:channel:{channel}"
    if key in sessions:
        sessions[key]["sessionId"] = None
        sessions[key]["systemSent"] = False
        with open(sessions_path, "w") as f:
            json.dump(sessions, f)
    import datetime
    ts = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    for fp in glob.glob(os.path.expanduser("~/.openclaw/agents/main/sessions/*.jsonl")):
        if ".reset." not in fp:
            os.rename(fp, fp + ".reset.loop-" + ts)
except Exception as e:
    print(f"Wipe failed: {e}")
WIPE
    launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway 2>/dev/null
    alert "🔄 **Loop detected:** Lobster was repeating. Auto-wiped session and restarted."
    log "LOOP FIX: Session wiped, gateway restarted"
  fi
fi

# Self-Heal — Auto-restart critical services if crashed
# ═══════════════════════════════════════════════════════
CRITICAL_SERVICES="ai.myndaix.inbox-watcher ai.myndaix.daemon ai.myndaix.smoke-watcher"

for svc in $CRITICAL_SERVICES; do
  svc_pid=$(launchctl list | awk -v s="$svc" '$3 == s {print $1}')
  svc_exit=$(launchctl list | awk -v s="$svc" '$3 == s {print $2}')
  plist_file="$HOME/Library/LaunchAgents/${svc}.plist"

  if [[ "$svc_pid" == "-" && -f "$plist_file" ]]; then
    log "SELF-HEAL: $svc crashed (exit $svc_exit) — restarting"
    launchctl remove "$svc" 2>/dev/null
    sleep 1
    launchctl load "$plist_file" 2>/dev/null
    new_pid=$(launchctl list | awk -v s="$svc" '$3 == s {print $1}')
    if [[ -n "$new_pid" && "$new_pid" != "-" ]]; then
      log "SELF-HEAL: $svc restarted (PID $new_pid)"
      alert "🔧 **Self-heal:** \`$svc\` crashed (exit $svc_exit) — auto-restarted (PID $new_pid)"
    else
      log "SELF-HEAL: $svc restart FAILED"
      alert "🚨 **Self-heal FAILED:** \`$svc\` could not restart — manual intervention needed"
    fi
  fi
done
