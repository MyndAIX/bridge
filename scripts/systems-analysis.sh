#!/usr/bin/env bash
# systems-analysis.sh — Layer 1: Daily pattern analysis across all agents
# Called by lobster-monitor.sh at 11 PM digest time
# Scans logs, heartbeats, cost, errors — groups into structural patterns
# Output: formatted analysis for Discord #alerts
set -euo pipefail

BRIDGE_DIR="${HOME}/.myndaix/bridge"
STATE_DIR="${BRIDGE_DIR}/state"
LOG_DIR="/tmp"
AGENTS="mini antman kilabz oracle recon harley mack smoke"
COST_LOG="${STATE_DIR}/cost-log.jsonl"
KNOWLEDGE_LOG="${STATE_DIR}/knowledge.jsonl"

# Collect errors from last 24h across all watcher logs
collect_errors() {
  local cutoff
  cutoff=$(date -v-24H '+%Y-%m-%d' 2>/dev/null || date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || echo "")

  local total_errors=0
  local error_agents=""
  local timeout_count=0
  local reject_count=0
  local fail_count=0
  local fallback_count=0

  for agent in $AGENTS; do
    local log="${LOG_DIR}/${agent}-watcher.log"
    [[ -f "$log" ]] || continue

    local errors
    errors=$(grep -c -i 'ERROR\|FAIL\|REJECT\|TIMEOUT\|BLOCKED' "$log" 2>/dev/null | head -1 || echo 0)
    errors=${errors//[^0-9]/}
    errors=${errors:-0}
    if (( errors > 0 )); then
      total_errors=$((total_errors + errors))
      error_agents="${error_agents} ${agent}(${errors})"
    fi

    local tc rc fc fbc
    tc=$(grep -c 'TIMEOUT' "$log" 2>/dev/null | head -1 || echo 0); tc=${tc//[^0-9]/}; tc=${tc:-0}
    rc=$(grep -c 'REJECT' "$log" 2>/dev/null | head -1 || echo 0); rc=${rc//[^0-9]/}; rc=${rc:-0}
    fc=$(grep -c 'FAILED' "$log" 2>/dev/null | head -1 || echo 0); fc=${fc//[^0-9]/}; fc=${fc:-0}
    fbc=$(grep -c -i 'fallback' "$log" 2>/dev/null | head -1 || echo 0); fbc=${fbc//[^0-9]/}; fbc=${fbc:-0}
    timeout_count=$((timeout_count + tc))
    reject_count=$((reject_count + rc))
    fail_count=$((fail_count + fc))
    fallback_count=$((fallback_count + fbc))
  done

  echo "ERRORS:${total_errors}"
  echo "AGENTS:${error_agents}"
  echo "TIMEOUTS:${timeout_count}"
  echo "REJECTS:${reject_count}"
  echo "FAILURES:${fail_count}"
  echo "FALLBACKS:${fallback_count}"
}

# Check heartbeat freshness
check_heartbeats() {
  local stale_agents=""
  local stale_count=0

  for agent in $AGENTS; do
    local hb="${STATE_DIR}/${agent}-heartbeat.json"
    [[ -f "$hb" ]] || continue

    local age
    age=$(python3 -c "
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
" "$hb" 2>/dev/null || echo 999999)

    if (( age > 86400 )); then
      local days=$((age / 86400))
      stale_agents="${stale_agents} ${agent}(${days}d)"
      stale_count=$((stale_count + 1))
    fi
  done

  echo "STALE_COUNT:${stale_count}"
  echo "STALE_AGENTS:${stale_agents}"
}

# Check dead-letter queue
check_dead_letter() {
  local dl_dir="${BRIDGE_DIR}/dead-letter"
  local count=0
  [[ -d "$dl_dir" ]] && count=$(find "$dl_dir" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "DEAD_LETTER:${count}"
}

# Check disk space
check_disk() {
  local available
  available=$(df -k / | tail -1 | awk '{print $4}')
  local gb=$((available / 1024 / 1024))
  echo "DISK_GB:${gb}"
}

# Identify structural patterns
identify_patterns() {
  local errors="$1"
  local timeouts="$2"
  local rejects="$3"
  local failures="$4"
  local fallbacks="$5"
  local stale="$6"
  local dead_letter="$7"
  local disk_gb="$8"

  local patterns=""

  # Pattern: Rate limit cascade
  if (( fallbacks > 3 )); then
    patterns="${patterns}RATE_LIMIT_CASCADE: ${fallbacks} fallbacks — agents hitting API limits and cascading to backup engines\n"
  fi

  # Pattern: Schema/validation fragility
  if (( rejects > 5 )); then
    patterns="${patterns}SCHEMA_FRAGILITY: ${rejects} rejections — tasks failing validation, likely missing frontmatter fields\n"
  fi

  # Pattern: Timeout spiral
  if (( timeouts > 3 )); then
    patterns="${patterns}TIMEOUT_SPIRAL: ${timeouts} timeouts — tasks too large or engines too slow, consider splitting\n"
  fi

  # Pattern: Silent failures
  if (( stale > 2 )); then
    patterns="${patterns}AGENT_DRIFT: ${stale} agents stale >24h — watchers may be hung or not receiving tasks\n"
  fi

  # Pattern: Security scanner noise
  if (( dead_letter > 20 )); then
    patterns="${patterns}SCANNER_NOISE: ${dead_letter} dead-letter files — scanner may be quarantining legitimate messages\n"
  fi

  # Pattern: Infrastructure pressure
  if (( disk_gb < 15 )); then
    patterns="${patterns}DISK_PRESSURE: ${disk_gb}GB free — approaching capacity, cleanup needed\n"
  fi

  # Pattern: Observability gap
  if (( failures > 0 && errors == 0 )); then
    patterns="${patterns}BLIND_FAILURES: tasks failing but no errors logged — observability gap\n"
  fi

  # Count structural patterns using identifier format (UPPERCASE_NAME:)
  local pattern_count=0
  if [[ -n "$patterns" ]]; then
    pattern_count=$(echo -e "$patterns" | grep -c '^[A-Z_]*:' || echo 0)
    pattern_count=${pattern_count//[^0-9]/}
    pattern_count=${pattern_count:-0}
  fi

  # Escalation: 3+ patterns = internal analysis insufficient
  if (( pattern_count >= 3 )); then
    patterns="${patterns}\nESCALATION_RECOMMENDED: ${pattern_count} structural patterns detected. Internal analysis insufficient \u2014 consider external architecture review (Perplexity, consultant, or fresh-eyes audit).\n"
  fi

  echo -e "$patterns"
}

# Generate the full analysis report
generate_report() {
  local error_data
  error_data=$(collect_errors)

  local total_errors=$(echo "$error_data" | grep '^ERRORS:' | cut -d: -f2)
  local error_agents=$(echo "$error_data" | grep '^AGENTS:' | cut -d: -f2-)
  local timeouts=$(echo "$error_data" | grep '^TIMEOUTS:' | cut -d: -f2)
  local rejects=$(echo "$error_data" | grep '^REJECTS:' | cut -d: -f2)
  local failures=$(echo "$error_data" | grep '^FAILURES:' | cut -d: -f2)
  local fallbacks=$(echo "$error_data" | grep '^FALLBACKS:' | cut -d: -f2)

  local heartbeat_data
  heartbeat_data=$(check_heartbeats)
  local stale_count=$(echo "$heartbeat_data" | grep '^STALE_COUNT:' | cut -d: -f2)
  local stale_agents=$(echo "$heartbeat_data" | grep '^STALE_AGENTS:' | cut -d: -f2-)

  local dead_letter=$(check_dead_letter | cut -d: -f2)
  local disk_gb=$(check_disk | cut -d: -f2)

  local patterns
  patterns=$(identify_patterns "$total_errors" "$timeouts" "$rejects" "$failures" "$fallbacks" "$stale_count" "$dead_letter" "$disk_gb")

  # Build report
  local report=""
  report+="**Systems Analysis — $(date '+%Y-%m-%d')**\n"
  report+="Errors: ${total_errors} | Timeouts: ${timeouts} | Rejects: ${rejects} | Failures: ${failures} | Fallbacks: ${fallbacks}\n"
  report+="Stale agents: ${stale_count} | Dead-letter: ${dead_letter} | Disk: ${disk_gb}GB free\n"

  if [[ -n "$error_agents" ]]; then
    report+="Agents with errors:${error_agents}\n"
  fi

  if [[ -n "$stale_agents" ]]; then
    report+="Stale agents:${stale_agents}\n"
  fi

  if [[ -n "$patterns" ]]; then
    report+="\n**Structural Patterns Detected:**\n${patterns}"
  else
    report+="\nNo structural patterns detected. System healthy."
  fi

  echo -e "$report"
}

# Main — output the report
generate_report
