#!/bin/bash
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Use actual HOME — don't hardcode (was hardcoded user-home for Mini, breaks portability)
export HOME="${HOME:-/Users/$(whoami)}"

# Source shared validation library with SHA256 integrity check
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
export BRIDGE_DIR
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"
_VALIDATE_LIB="$BRIDGE_DIR/watchers/lib/validate.sh"
_VALIDATE_HASH="$BRIDGE_DIR/watchers/lib/validate.sh.sha256"
if [[ -f "$_VALIDATE_LIB" ]]; then
  if [[ -f "$_VALIDATE_HASH" ]]; then
    if ! (cd "$(dirname "$_VALIDATE_LIB")" && shasum -a 256 -c "$_VALIDATE_HASH" >/dev/null 2>&1); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [mack-watcher] FATAL: validate.sh SHA256 mismatch — refusing to load" >&2
      exit 1
    fi
  fi
  source "$_VALIDATE_LIB" || { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [mack-watcher] FATAL: validate.sh failed to load" >&2; exit 1; }
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [mack-watcher] FATAL: validate.sh not found — refusing to run without validation" >&2
  exit 1
fi

# Daemon routes tasks here; inbox/ is for non-task messages only
TASK_QUEUE="$HOME/.myndaix/bridge/inbox/mack"
INBOX="$TASK_QUEUE"
OUTBOX="$HOME/.myndaix/bridge/inbox/lobster"
PROCESSED="$HOME/.myndaix/bridge/processed"
LOCKDIR="$HOME/.myndaix/bridge/locks/mack-watcher.lock"
LOG="$HOME/.myndaix/bridge/watchers/mack-watcher.log"
RUNNER="$HOME/.myndaix/bridge/watchers/mack-runner.sh"
STATE_FILE="$HOME/.myndaix/bridge/state/mack-daily-runs.json"
WORKTREE_ROOT="/tmp/mack-worktrees"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

MAX_TASK_BYTES=51200
DEFAULT_TIMEOUT=900
MAX_TIMEOUT=2400
STALE_LOCK_SECS=900

mkdir -p "$TASK_QUEUE" "$OUTBOX" "$PROCESSED" "$WORKTREE_ROOT" "$HOME/.myndaix/bridge/locks" "$HOME/.myndaix/bridge/state" "$HOME/.myndaix/bridge/watchers"



# Heartbeat — write after every task for readiness monitoring.
# Mirrors common.sh's FIX 9: terminal-state guard + daily reset.
write_heartbeat() {
  local task_name="${1:-unknown}"
  local result="${2:-unknown}"
  local state_file="$HOME/.myndaix/bridge/state/mack-heartbeat.json"
  local now today
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  today=$(date -u +"%Y-%m-%d")

  # Read prior count + date; reset count when the day rolls over.
  local today_count=0
  local prior_date=""
  if [ -f "$state_file" ]; then
    today_count=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('tasks_today',0))" "$state_file" 2>/dev/null || echo 0)
    prior_date=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('date',''))" "$state_file" 2>/dev/null || echo "")
  fi
  if [[ "$prior_date" != "$today" ]]; then
    today_count=0
  fi

  # Only count terminal statuses — claimed/dispatched/queued/in_progress are
  # transitional and would inflate the daily total.
  local result_lc
  result_lc=$(printf '%s' "$result" | tr '[:upper:]' '[:lower:]')
  case "$result_lc" in
    pass|success|completed|failed|skipped|timeout|rejected|context_overflow|merge_conflict)
      today_count=$((today_count + 1))
      ;;
  esac

  cat > "$state_file" << HBEOF
{"agent":"mack","last_beat":"$now","date":"$today","last_task":"$task_name","last_result":"$result","tasks_today":$today_count}
HBEOF
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [mack] $*" >> "$LOG"
}

log_task() {
  local task_id="$1"
  local agent="$2"
  local type="$3"
  local task_status="$4"
  local model="${5:-unknown}"
  local tokens_in="${6:-0}"
  local tokens_out="${7:-0}"
  local error="${8:-null}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Minimal JSON-safe escaping for known-safe internal values
  printf '{"task_id":"%s","agent":"%s","type":"%s","status":"%s","model":"%s","tokens_in":%s,"tokens_out":%s,"error":"%s","timestamp":"%s"}\n' \
    "$task_id" "$agent" "$type" "$task_status" "$model" "$tokens_in" "$tokens_out" "$error" "$timestamp" \
    >> "$HOME/.myndaix/telemetry/tasks.jsonl"
}

# ── Upgrade 2: AGENT_NAME + inline validate_task + check_pain ──
# (mack-watcher does not source lib/common.sh — these mirror the common.sh versions)
AGENT_NAME="mack"

validate_task() {
  local task_file="$1"
  local required=("from" "to" "type" "subject")
  local task_basename
  task_basename=$(basename "$task_file" .md)
  local rejected_dir="$HOME/.myndaix/bridge/rejected"
  mkdir -p "$rejected_dir"

  local field
  for field in "${required[@]}"; do
    if ! grep -q "^${field}:" "$task_file"; then
      log_task "$task_basename" "${AGENT_NAME:-unknown}" "unknown" "rejected" "none" 0 0 "missing_field_${field}"
      mv "$task_file" "$rejected_dir/" 2>/dev/null || true
      echo "[REJECT] Missing required field: $field — $(basename "$task_file")" >&2
      return 1
    fi
  done

  local task_type
  task_type=$(grep "^type:" "$task_file" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
  case "$task_type" in
    task|review|research|creative) ;;
    *)
      log_task "$task_basename" "${AGENT_NAME:-unknown}" "$task_type" "rejected" "none" 0 0 "invalid_type"
      mv "$task_file" "$rejected_dir/" 2>/dev/null || true
      echo "[REJECT] Invalid type: $task_type — $(basename "$task_file")" >&2
      return 1 ;;
  esac
  return 0
}

check_pain() {
  local agent="$1"
  local window_seconds=3600
  local threshold=3
  local now
  now=$(date +%s)
  local failures=0
  local jsonl="$HOME/.myndaix/telemetry/tasks.jsonl"
  local state_dir="$HOME/.myndaix/bridge/state"
  local lobster_inbox="$HOME/.myndaix/bridge/inbox/lobster"

  [ -f "$jsonl" ] || return 0
  [ -f "$state_dir/${agent}-paused" ] && return 0

  while IFS= read -r line; do
    local ts
    ts=$(printf '%s\n' "$line" | python3 -c "import sys,json
try:
    print(json.loads(sys.stdin.readline()).get('timestamp',''))
except Exception:
    pass" 2>/dev/null)
    if [ -n "$ts" ]; then
      local entry_time
      entry_time=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)
      local age=$((now - entry_time))
      if [ "$age" -lt "$window_seconds" ]; then
        failures=$((failures + 1))
      fi
    fi
  done < <(grep "\"agent\":\"$agent\"" "$jsonl" 2>/dev/null | grep "\"status\":\"failed\"" | tail -10)

  if [ "$failures" -ge "$threshold" ]; then
    mkdir -p "$state_dir"
    echo "PAUSED" > "$state_dir/${agent}-paused"
    log_task "system" "$agent" "system" "paused" "circuit-breaker" 0 0 "${failures}_failures_in_1h"
    mkdir -p "$lobster_inbox"
    local alert_file="$lobster_inbox/pain-alert-${agent}-$(date +%s).md"
    cat > "$alert_file" <<ALERT_EOF
---
from: ${AGENT_NAME:-system}
to: lobster
type: alert
subject: "Circuit breaker triggered for $agent"
priority: 1
---

Circuit breaker triggered — $agent failed $failures times in the last hour. Paused until manual review.

To resume: rm "$state_dir/${agent}-paused"
ALERT_EOF
    return 1
  fi
  return 0
}

# -- check_dedupe inline (mirrors guardrails.sh — 24h window, atomic file marker) --
_sanitize_id() {
  local id="$1"
  id="${id//[\/\\]/_}"
  id="${id//../_}"
  id=$(printf '%s' "$id" | tr -cd 'a-zA-Z0-9._-')
  printf '%s' "${id:0:200}"
}

check_dedupe() {
  local task_id
  task_id=$(_sanitize_id "$1")
  [[ -z "$task_id" ]] && return 0
  local dir="$HOME/.myndaix/bridge/state/dedupe"
  local file="${dir}/${task_id}.done"
  mkdir -p "$dir"
  if [[ -f "$file" ]]; then
    local now file_age age_seconds
    now=$(date +%s)
    if stat -f %m "$file" &>/dev/null; then
      file_age=$(stat -f %m "$file")
    else
      file_age=$(stat -c %Y "$file")
    fi
    age_seconds=$(( now - file_age ))
    if (( age_seconds < 86400 )); then
      return 1
    fi
    rm -f "$file"
  fi
  touch "$file"
  return 0
}

# -- query_memory inline (Upgrade 3 — mirrors common.sh) --
query_memory() {
  local domain="$1"
  local category="${2:-}"
  local limit="${3:-20}"
  local where="WHERE deprecated=0 AND domain='$domain'"
  if [ -n "$category" ]; then
    where="$where AND category='$category'"
  fi
  sqlite3 "$HOME/.myndaix/memory.db" \
    "UPDATE memory SET last_accessed=datetime('now'), access_count=access_count+1
     WHERE id IN (SELECT id FROM memory $where ORDER BY confidence DESC, last_accessed DESC LIMIT $limit);
     SELECT content FROM memory $where ORDER BY confidence DESC, last_accessed DESC LIMIT $limit"
}

# -- claim_task / complete_task inline (Upgrade 5 — mack does not source common.sh) --
claim_task() {
  local agent="$1"
  local _a
  _a=$(printf '%s' "$agent" | sed "s/'/''/g")
  sqlite3 "$HOME/.myndaix/memory.db" \
    "UPDATE tasks SET status='claimed', claimed_at=datetime('now')
     WHERE id = (SELECT id FROM tasks WHERE agent='$_a' AND status='queued'
                 ORDER BY priority ASC, dispatched_at ASC LIMIT 1)
     RETURNING id || '|' || type || '|' || COALESCE(objective,'') || '|' || COALESCE(body,'') || '|' || COALESCE(branch,'') || '|' || COALESCE(inbox_file,'')" 2>/dev/null
}

complete_task() {
  local task_id="$1" status="$2" result_summary="${3:-}" result_path="${4:-}" error="${5:-}"
  local _id _sum _path _err
  _id=$(printf '%s' "$task_id" | sed "s/'/''/g")
  _sum=$(printf '%s' "$result_summary" | sed "s/'/''/g")
  _path=$(printf '%s' "$result_path" | sed "s/'/''/g")
  _err=$(printf '%s' "$error" | sed "s/'/''/g")
  case "$status" in
    success|completed)
      sqlite3 "$HOME/.myndaix/memory.db" \
        "UPDATE tasks SET status='completed', completed_at=datetime('now'),
         result_summary='$_sum', result_path='$_path' WHERE id='$_id'" 2>/dev/null
      log_task "$task_id" "queue" "task" "completed" "queue" 0 0 "null"
      ;;
    failed)
      local rc_max rc max
      rc_max=$(sqlite3 "$HOME/.myndaix/memory.db" "SELECT retry_count || '|' || max_retries FROM tasks WHERE id='$_id'" 2>/dev/null)
      [ -z "$rc_max" ] && return 1
      rc=$(printf '%s' "$rc_max" | cut -d'|' -f1)
      max=$(printf '%s' "$rc_max" | cut -d'|' -f2)
      if [ "$rc" -lt "$max" ]; then
        sqlite3 "$HOME/.myndaix/memory.db" "UPDATE tasks SET status='queued', claimed_at=NULL, retry_count=retry_count+1, error='$_err' WHERE id='$_id'"
        log_task "$task_id" "queue" "task" "retry" "queue" 0 0 "$_err"
      else
        sqlite3 "$HOME/.myndaix/memory.db" "UPDATE tasks SET status='failed', completed_at=datetime('now'), error='$_err' WHERE id='$_id'"
        log_task "$task_id" "queue" "task" "dead_letter" "queue" 0 0 "$_err"
      fi
      ;;
  esac
}

# -- detect_pattern / detect_failure_pattern inline (Upgrade 6 — mack does not source common.sh) --
_pattern_fingerprint() {
  python3 -c "
import hashlib, re, sys
STOPWORDS = {'the','and','for','with','from','that','this','into','have','but','not','your','what','will','also','now','get','task','review','please'}
agent, ttype, objective, repo = sys.argv[1:5]
tokens = sorted({tok for tok in re.findall(r'[a-z]+', objective.lower())
                 if tok not in STOPWORDS and len(tok) >= 3})
keywords = sorted(sorted(tokens, key=len, reverse=True)[:3])
raw = f'{agent}|{ttype}|{repo or "*"}|{"|".join(keywords)}'
print(hashlib.sha256(raw.encode()).hexdigest()[:16])
" "$1" "$2" "$3" "$4" 2>/dev/null
}

detect_pattern() {
  local agent="$1" type="$2" objective="$3" repo="$4" task_id="$5"
  local fp
  fp=$(_pattern_fingerprint "$agent" "$type" "$objective" "$repo")
  [ -z "$fp" ] && return 1
  local rec_type="prompt_improvement"
  case "$agent" in
    kilabz|oracle) rec_type="lint_rule" ;;
    recon|harley) rec_type="template" ;;
  esac
  local _agent _type _rec _fp _tid _desc
  _agent=$(printf '%s' "$agent" | sed "s/'/''/g")
  _type=$(printf '%s' "$type" | sed "s/'/''/g")
  _rec=$(printf '%s' "$rec_type" | sed "s/'/''/g")
  _fp=$(printf '%s' "$fp" | sed "s/'/''/g")
  _tid=$(printf '%s' "$task_id" | sed "s/'/''/g")
  _desc=$(printf '%s' "$objective" | head -c 200 | sed "s/'/''/g")
  local existing
  existing=$(sqlite3 "$HOME/.myndaix/memory.db" "SELECT id FROM patterns WHERE fingerprint='$_fp'" 2>/dev/null)
  if [ -z "$existing" ]; then
    sqlite3 "$HOME/.myndaix/memory.db" \
      "INSERT INTO patterns (pattern_type, description, fingerprint, occurrences, agent, recommended_type, evidence_task_ids)
       VALUES ('success', '$_desc', '$_fp', 1, '$_agent', '$_rec', '$_tid')" 2>/dev/null
    return 0
  fi
  sqlite3 "$HOME/.myndaix/memory.db" \
    "UPDATE patterns SET occurrences=occurrences+1, last_seen=datetime('now'),
     evidence_task_ids = COALESCE(evidence_task_ids || ',', '') || '$_tid'
     WHERE fingerprint='$_fp'" 2>/dev/null
  local row pid occ sent promo rej desc agent_v rec_v evid
  row=$(sqlite3 "$HOME/.myndaix/memory.db" \
    "SELECT id, occurrences, COALESCE(proposal_sent_at,''), COALESCE(promoted,0), COALESCE(rejected,0),
            description, agent, recommended_type, COALESCE(evidence_task_ids,'')
     FROM patterns WHERE fingerprint='$_fp'")
  pid=$(echo "$row" | cut -d'|' -f1)
  occ=$(echo "$row" | cut -d'|' -f2)
  sent=$(echo "$row" | cut -d'|' -f3)
  promo=$(echo "$row" | cut -d'|' -f4)
  rej=$(echo "$row" | cut -d'|' -f5)
  desc=$(echo "$row" | cut -d'|' -f6)
  agent_v=$(echo "$row" | cut -d'|' -f7)
  rec_v=$(echo "$row" | cut -d'|' -f8)
  evid=$(echo "$row" | cut -d'|' -f9)
  if [ "${occ:-0}" -ge 3 ] && [ -z "$sent" ] && [ "$promo" = "0" ] && [ "$rej" = "0" ]; then
    local lobster_inbox="${PROMOTION_LOBSTER_INBOX:-$HOME/.myndaix/bridge/inbox/lobster}"
    mkdir -p "$lobster_inbox"
    local file="$lobster_inbox/promotion-${pid}-$(date +%s).md"
    cat > "$file" <<PROPOSAL_EOF
---
from: pattern-detector
to: lobster
type: alert
subject: "[PROMOTION] $rec_v: $desc"
priority: 3
---

Pattern detected $occ times.

Pattern ID: $pid
Fingerprint: $fp
Agent: $agent_v
Description: $desc
Recommended type: $rec_v
Evidence task IDs: $evid
PROPOSAL_EOF
    sqlite3 "$HOME/.myndaix/memory.db" "UPDATE patterns SET proposal_sent_at = datetime('now') WHERE id=$pid"
    log_task "PATTERN-$pid" "$agent_v" "pattern" "proposed" "auto" 0 0 "occ=$occ rec=$rec_v"
  fi
  return 0
}

detect_failure_pattern() {
  local agent="$1" type="$2" objective="$3" repo="$4" task_id="$5" error="${6:-}"
  local fp
  fp=$(_pattern_fingerprint "$agent" "$type" "$objective" "$repo")
  [ -z "$fp" ] && return 1
  fp="F$fp"
  local _agent _fp _tid _desc _err
  _agent=$(printf '%s' "$agent" | sed "s/'/''/g")
  _fp=$(printf '%s' "$fp" | sed "s/'/''/g")
  _tid=$(printf '%s' "$task_id" | sed "s/'/''/g")
  _desc=$(printf '%s' "$objective" | head -c 200 | sed "s/'/''/g")
  _err=$(printf '%s' "$error" | head -c 100 | sed "s/'/''/g")
  local existing
  existing=$(sqlite3 "$HOME/.myndaix/memory.db" "SELECT id FROM patterns WHERE fingerprint='$_fp'" 2>/dev/null)
  if [ -z "$existing" ]; then
    sqlite3 "$HOME/.myndaix/memory.db" \
      "INSERT INTO patterns (pattern_type, description, fingerprint, occurrences, agent, evidence_task_ids)
       VALUES ('failure', '$_desc [err: $_err]', '$_fp', 1, '$_agent', '$_tid')" 2>/dev/null
  else
    sqlite3 "$HOME/.myndaix/memory.db" \
      "UPDATE patterns SET occurrences=occurrences+1, last_seen=datetime('now'),
       evidence_task_ids = COALESCE(evidence_task_ids || ',', '') || '$_tid'
       WHERE fingerprint='$_fp'" 2>/dev/null
  fi
  return 0
}






# ── Interactive session guard ──
# Fail-closed: if the SSH probe can't determine MacBook state (timeout, network
# blip, host down), DEFER rather than proceed. Uncertainty about whether a
# human is at the keyboard must not be resolved by running anyway.
MACBOOK_IP="${MACBOOK_TAILSCALE_IP:-}"
ssh -o ConnectTimeout=2 -o BatchMode=yes "stevenfernandez@$MACBOOK_IP" 'pgrep -f "claude" >/dev/null 2>&1' </dev/null >/dev/null 2>&1
SSH_RC=$?
case "$SSH_RC" in
  0)
    log "Interactive Mack session active on MacBook — deferring"
    exit 0
    ;;
  1)
    # Remote ran cleanly, no claude process — safe to proceed
    :
    ;;
  *)
    # Any other rc = SSH itself failed (timeout, refused, host down, auth, etc.)
    log "Interactive-guard probe failed (ssh rc=$SSH_RC) — deferring (fail-closed)"
    exit 0
    ;;
esac

# ── Stale process reaper ──
while IFS= read -r reap_line; do
  cpid=$(echo "$reap_line" | awk '{print $2}')
  elapsed=$(ps -o etime= -p "$cpid" 2>/dev/null | tr -d ' ')
  if [[ -n "$elapsed" ]]; then
    if echo "$elapsed" | grep -qE '^[0-9]+-|^[0-9]+:[0-9]+:[0-9]+'; then
      log "REAPER: Killing stale mack claude PID=$cpid (elapsed=$elapsed)"
      kill -9 "$cpid" 2>/dev/null || true
    fi
  fi
done < <(ps aux | grep "claude.*dangerously-skip" | grep -v grep 2>/dev/null || true)

# ── Concurrency limit ──
MAX_CONCURRENT_CLAUDE=3
current_claude=$(ps aux | grep "claude.*dangerously-skip" | grep -v grep 2>/dev/null | wc -l | tr -d ' ')
if [ "$current_claude" -ge "$MAX_CONCURRENT_CLAUDE" ] 2>/dev/null; then
  log "Concurrency limit: $current_claude claude processes (max $MAX_CONCURRENT_CLAUDE) — skipping"
  exit 0
fi


iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

safe_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-48
}

write_result() {
  local subject="$1"
  local branch="$2"
  local worktree="$3"
  local engine="$4"
  local validation="$5"
  local body_file="$6"
  local ts suffix
  ts=$(date -u '+%Y%m%d%H%M%S')
  suffix=$(head -c 4 /dev/urandom | xxd -p | cut -c1-8)
  local out="$OUTBOX/${ts}-mack-result-${suffix}.md"
  {
    echo "---"
    echo "from: mack"
    echo "to: lobster"
    echo "type: result"
    echo "subject: \"Re: ${subject}\""
    echo "branch: ${branch}"
    echo "worktree: ${worktree}"
    echo "engine: ${engine}"
    echo "validation: ${validation}"
    echo "created: $(iso_now)"
    [ -n "${task_id:-}" ] && echo "task_id: ${task_id}"
    echo "---"
    echo
    cat "$body_file"
  } > "$out"
  log "Wrote result: $out (validation=$validation)"
}

reject_task() {
  local task_name="$1"
  local reason="$2"
  local body
  body=$(mktemp)
  {
    echo "Task rejected by fail-closed validation."
    echo
    echo "Reason: $reason"
    echo "Task: $task_name"
  } > "$body"
  write_result "$task_name" "n/a" "n/a" "mack-watcher" "REJECTED" "$body"
  rm -f "$body"
}

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$LOCKDIR/pid"
    date +%s > "$LOCKDIR/start_time"
    trap 'rm -rf "$LOCKDIR"' EXIT
    return 0
  fi

  # Empty lock dir (no start_time) = orphaned lock, reclaim immediately
  if [[ ! -f "$LOCKDIR/start_time" ]]; then
    log "WARN: orphaned lock dir (no start_time), reclaiming"
    rm -rf "$LOCKDIR"
    if mkdir "$LOCKDIR" 2>/dev/null; then
      echo "$$" > "$LOCKDIR/pid"
      date +%s > "$LOCKDIR/start_time"
      trap 'rm -rf "$LOCKDIR"' EXIT
      return 0
    fi
    return 1
  fi

  # Lock has start_time — check if stale
  local start now
  start=$(cat "$LOCKDIR/start_time" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now - start > STALE_LOCK_SECS )); then
    if [[ -f "$LOCKDIR/pid" ]]; then
      local old_pid
      old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
      if [[ -n "$old_pid" ]]; then
        kill "$old_pid" 2>/dev/null || true
      fi
    fi
    log "WARN: stale lock (age=$((now - start))s), reclaiming"
    rm -rf "$LOCKDIR"
    if mkdir "$LOCKDIR" 2>/dev/null; then
      echo "$$" > "$LOCKDIR/pid"
      date +%s > "$LOCKDIR/start_time"
      trap 'rm -rf "$LOCKDIR"' EXIT
      return 0
    fi
  fi
  return 1
}

parse_frontmatter_json() {
  local file="$1"
  python3 -c "
import sys, re, json

content = open(sys.argv[1], encoding='utf-8').read()
m = re.match(r'^---\s*\n(.*?)\n---\s*(?:\n|\Z)', content, re.DOTALL)
if not m:
    sys.exit('missing_frontmatter')

data = {}
for line in m.group(1).split('\n'):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    # Skip YAML block scalar indicators and continuation lines
    if line.startswith(('- ', '  ', '> ', '| ')) or line in ('|', '>', '|-', '>-'):
        continue
    idx = line.find(':')
    if idx > 0:
        key = line[:idx].strip()
        # Reject keys with spaces (likely injected from multiline values)
        if ' ' in key or not re.match(r'^[a-zA-Z_][a-zA-Z0-9_-]*$', key):
            continue
        val = line[idx+1:].strip().strip('\"').strip(\"'\")
        data[key] = val

print(json.dumps(data))
" "$file"
}

# Extract all frontmatter fields in ONE python3 call instead of N separate calls.
# Sets shell variables directly: fm_type, fm_tier, fm_task_id, fm_from, etc.
# Falls back to json_get() for any field not pre-extracted.
extract_all_fields() {
  local json="$1"
  eval "$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
fields = ['type','tier','task_id','from','dispatch_to','chain_id','chain_depth',
          'repo','project','scope','timeout','subject','priority','access_level','branch']
for f in fields:
    val = data.get(f, '')
    if isinstance(val, str):
        # Shell-safe: escape single quotes
        safe = val.replace(\"'\", \"'\\\\''\")
        print(f\"fm_{f}='{safe}'\")
    else:
        print(f\"fm_{f}=''\")
" "$json")"
}

json_get() {
  local json="$1"
  local key="$2"
  python3 -c "
import json, sys
data = json.loads(sys.argv[1])
val = data.get(sys.argv[2], '')
print(val if isinstance(val, str) else json.dumps(val))
" "$json" "$key"
}

verify_hooks_loaded() {
  if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    log "WARNING: missing $CLAUDE_SETTINGS — scoped permissions in runner are primary security boundary"
  fi
  # Scoped permissions (--permission-mode dontAsk + --allowedTools) in mack-runner.sh
  # are the primary security boundary. Hooks are defense-in-depth, not blocking.
  return 0
}

ensure_budget_file() {
  python3 - "$STATE_FILE" <<'PY'
import json, os, sys, datetime
path = sys.argv[1]
today = datetime.date.today().isoformat()
default = {
  "date": today,
  "runs": 0,
  "max": 50,
  "failures": 0,
  "max_failures": 10,
}
if not os.path.exists(path):
    with open(path, "w") as f:
        json.dump(default, f)
    raise SystemExit(0)
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = default
if data.get("date") != today:
    data = {
      "date": today,
      "runs": 0,
      "max": int(data.get("max", 50) or 50),
      "failures": 0,
      "max_failures": int(data.get("max_failures", 10) or 10),
    }
with open(path, "w") as f:
    json.dump(data, f)
PY
}

budget_block_reason() {
  python3 - "$STATE_FILE" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    d=json.load(f)
runs=int(d.get("runs",0)); max_runs=int(d.get("max",50))
fails=int(d.get("failures",0)); max_fails=int(d.get("max_failures",10))
if runs >= max_runs:
    print(f"Daily run cap reached ({runs}/{max_runs})")
elif fails >= max_fails:
    print(f"Daily failure cap reached ({fails}/{max_fails})")
PY
}

budget_increment() {
  local key="$1"
  python3 - "$STATE_FILE" "$key" <<'PY'
import json,sys
path,key=sys.argv[1],sys.argv[2]
with open(path) as f:
    d=json.load(f)
d[key]=int(d.get(key,0))+1
with open(path,"w") as f:
    json.dump(d,f)
PY
}

preflight_check() {
  # MacBook runs Claude Code directly — no proxy needed
  # Just verify claude CLI is available
  if command -v claude >/dev/null 2>&1; then
    return 0
  fi
  log "ERROR: claude CLI not found in PATH"
  return 1
}

pick_oldest_task() {
  ls -1tr "$INBOX"/*.md 2>/dev/null | grep -v -e '\.tmp' -e '~syncthing~' -e '\.syncthing\.' | head -n 1 || true
}

archive_task() {
  local task_file="$1"
  local task_name
  task_name=$(basename "$task_file")
  # Syncthing race fix: rename to non-.md first so watcher won't re-pick it up
  local tmp_name="${task_file}.archived"
  mv "$task_file" "$tmp_name" 2>/dev/null || return 0
  local target="$PROCESSED/$task_name"
  if [[ -e "$target" ]]; then
    target="$PROCESSED/$(date -u '+%Y%m%d%H%M%S')-$task_name"
  fi
  mv "$tmp_name" "$target"
}

if ! verify_hooks_loaded; then
  exit 1
fi

if ! acquire_lock; then
  log "Lock held by active run, skipping"
  exit 0
fi

# ── Pause check (Upgrade 2) — runs FIRST, before any claim ──
# Must precede claim_task so a paused state doesn't leak claimed-without-complete
# rows into telemetry. Mack is single-task per run, so plain exit 0 is correct.
if [ -f "$HOME/.myndaix/bridge/state/${AGENT_NAME}-paused" ]; then
  log "[PAUSED] ${AGENT_NAME} is paused by circuit breaker — exiting"
  log_task "system" "${AGENT_NAME}" "system" "skipped" "none" 0 0 "agent_paused"
  exit 0
fi

# Try SQLite task queue first (Upgrade 5 parallel run)
SQLITE_CLAIM=$(claim_task "${AGENT_NAME:-unknown}" 2>/dev/null)
if [ -n "$SQLITE_CLAIM" ]; then
  TASK_ID=$(echo "$SQLITE_CLAIM" | cut -d'|' -f1)
  TASK_FILE=$(echo "$SQLITE_CLAIM" | cut -d'|' -f6)
  CLAIM_SOURCE="sqlite"
  log "SQLite claim: id=$TASK_ID inbox_file=$TASK_FILE"
else
  TASK_ID=""
  CLAIM_SOURCE="inbox"
  TASK_FILE=$(pick_oldest_task)
fi
if [[ -z "$TASK_FILE" ]]; then
  log "No tasks in inbox"
  exit 0
fi

TASK_NAME=$(basename "$TASK_FILE")
log "Processing task: $TASK_NAME"
log_task "${TASK_NAME%.md}" "mack" "task" "claimed" "unknown"

# -- Schema validation (soft — warn but don't reject for authorized senders) --
# (Pause check now runs above, before any claim.)

# ── Schema validation (Upgrade 2 — replaces validate-task.sh) ──
# NOTE: mack previously used soft validation. Upgrade 2 makes it authoritative/hard.
if ! validate_task "$TASK_FILE"; then
  log "REJECTED: $TASK_NAME — failed schema validation (moved to rejected/)"
  exit 0
fi
log "Schema validation passed for $TASK_NAME"


TASK_SIZE=$(wc -c < "$TASK_FILE" | tr -d ' ')
if (( TASK_SIZE > MAX_TASK_BYTES )); then
  reject_task "$TASK_NAME" "task exceeds max size (${TASK_SIZE} bytes > ${MAX_TASK_BYTES} bytes)"
  archive_task "$TASK_FILE"
  exit 0
fi

frontmatter_json=""
if ! frontmatter_json=$(parse_frontmatter_json "$TASK_FILE" 2>/dev/null); then
  log "Skipping non-task file: $TASK_NAME - moving to processed (no valid frontmatter)"
  reject_task "$TASK_NAME" "no valid frontmatter found -- file skipped"
  archive_task "$TASK_FILE"
  exit 0
fi

# Extract ALL fields in one python3 call (replaces ~10 separate json_get calls)
extract_all_fields "$frontmatter_json"

task_type="$fm_type"
if [[ "$task_type" != "task" && "$task_type" != "review" && "$task_type" != "handoff" ]]; then
  log "WARN: non-actionable in queue (type=$task_type): $TASK_NAME — archiving"
  archive_task "$TASK_FILE"
  exit 0
fi

# Sanitize extracted values — strip control chars to prevent injection
tier=$(echo "$fm_tier" | tr -d '\n\r')
task_id=$(echo "$fm_task_id" | tr -d '\n\r' | tr -cd 'a-zA-Z0-9._-')
from=$(echo "$fm_from" | tr -d '\n\r' | tr -cd 'a-zA-Z0-9._-')
dispatch_to=$(echo "$fm_dispatch_to" | tr -d '\n\r' | tr -cd 'a-zA-Z0-9._-')
chain_id=$(echo "$fm_chain_id" | tr -d '\n\r' | tr -cd 'a-zA-Z0-9._-')
chain_depth=$(echo "$fm_chain_depth" | tr -d '\n\r' | tr -cd '0-9')
subject="$fm_subject"

# Default tier to auto for authorized senders (Lobster's context compression drops this field)
if [[ -z "$tier" ]]; then
  tier="auto"
  log "Defaulting tier to 'auto' for $TASK_NAME (field was missing)"
fi
if [[ "$tier" != "auto" ]]; then
  reject_task "$TASK_NAME" "tier is not 'auto' (got: '$tier')"
  archive_task "$TASK_FILE"
  exit 0
fi
# Authorized senders: use shared trusted-senders.conf if available, else hardcoded fallback
TRUSTED_FILE="$BRIDGE_DIR/state/trusted-senders.conf"
if [[ -f "$TRUSTED_FILE" ]]; then
  if [[ -z "$from" ]] || ! grep -Fxq "$from" "$TRUSTED_FILE" 2>/dev/null; then
    reject_task "$TASK_NAME" "sender '$from' is not in trusted-senders.conf"
    archive_task "$TASK_FILE"
    exit 0
  fi
else
  # Fallback: hardcoded list if conf file missing
  AUTHORIZED_SENDERS="lobster mini jefe mack antman kilabz oracle recon harley cli"
  if [[ -z "$from" ]] || ! echo "$AUTHORIZED_SENDERS" | grep -Fqw "$from"; then
    reject_task "$TASK_NAME" "sender '$from' is not authorized for mack (allowed: $AUTHORIZED_SENDERS)"
    archive_task "$TASK_FILE"
    exit 0
  fi
fi

# ── Dedupe (24h) — skip if this task_id was processed recently ──
if [[ -n "$task_id" ]]; then
  if ! check_dedupe "$task_id"; then
    log "DEDUPE: $TASK_NAME (task_id=$task_id) already processed within 24h — skipping"
    archive_task "$TASK_FILE"
    exit 0
  fi
fi

ensure_budget_file
budget_reason=$(budget_block_reason || true)
if [[ -n "$budget_reason" ]]; then
  log "$budget_reason -- task stays in inbox for next budget window"
  exit 0
fi

repo="$fm_repo"
if [[ -z "$repo" ]]; then
  repo="$fm_project"
fi
if [[ -z "$repo" ]]; then
  repo="$fm_scope"
fi
if [[ -z "$repo" ]]; then
  repo="$HOME"
fi

# Two-machine path translation: dispatches from the peer machine carry
# paths under $PEER_HOME (e.g. Mini's $HOME). Remap them to the local $HOME
# so the worktree resolves correctly. Configure PEER_HOME in ~/.myndaix/.secrets.
PEER_HOME="${PEER_HOME:-}"
if [[ -n "$PEER_HOME" && "$repo" == "$PEER_HOME"/* ]]; then
  repo="$HOME${repo#$PEER_HOME}"
  log "Path translated: \$PEER_HOME → \$HOME: $repo"
fi

if [[ ! -d "$repo" ]]; then
  log "Repo path not found: $repo — leaving in inbox for retry"
  exit 0
fi
# Worktree isolation requires a git repo — if not git, run in-place
USE_WORKTREE=true
if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  USE_WORKTREE=false
  log "Repo is not a git repo, running in-place: $repo"
fi

timeout_secs="$fm_timeout"
if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]]; then
  timeout_secs=$DEFAULT_TIMEOUT
fi
if (( timeout_secs > MAX_TIMEOUT )); then
  timeout_secs=$MAX_TIMEOUT
fi
if (( timeout_secs < 60 )); then
  timeout_secs=60
fi

TASK_SLUG=$(safe_slug "${TASK_NAME%.md}")
if [[ -z "$TASK_SLUG" ]]; then
  TASK_SLUG="task"
fi
TASK_TS=$(date +%s)
TASK_SLUG="${TASK_SLUG}-${TASK_TS}"
WORKTREE_DIR="$WORKTREE_ROOT/$TASK_SLUG"

# Branch-aware build: if frontmatter specifies branch:, use it directly so
# downstream reviewers see work on the intended feature branch (not mack/*).
# Sanitize: strip control chars and disallow path traversal.
task_branch=$(echo "${fm_branch:-}" | tr -d '\n\r' | tr -cd 'a-zA-Z0-9._/-')

if [[ "$USE_WORKTREE" == "true" ]]; then
  if [[ -n "$task_branch" ]]; then
    BRANCH_NAME="$task_branch"
    # Try existing branch first (local or remote); create fresh as last resort.
    if ! git -C "$repo" worktree add "$WORKTREE_DIR" "$task_branch" >/dev/null 2>&1; then
      git -C "$repo" fetch origin "$task_branch" 2>/dev/null || true
      if ! git -C "$repo" worktree add "$WORKTREE_DIR" "$task_branch" >/dev/null 2>&1; then
        if ! git -C "$repo" worktree add "$WORKTREE_DIR" -b "$task_branch" >/dev/null 2>&1; then
          body=$(mktemp)
          {
            echo "Failed to create or check out task branch."
            echo "Repo: $repo"
            echo "Requested branch: $task_branch"
          } > "$body"
          write_result "$TASK_NAME" "$task_branch" "$WORKTREE_DIR" "mack-watcher" "FAILED" "$body"
          rm -f "$body"
          budget_increment failures
          archive_task "$TASK_FILE"
          exit 0
        fi
      fi
    fi
    log "Using task-specified branch: $BRANCH_NAME"
  else
    BRANCH_NAME="mack/${TASK_SLUG}"
    if ! git -C "$repo" worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" >/dev/null 2>&1; then
      body=$(mktemp)
      {
        echo "Failed to create git worktree."
        echo "Repo: $repo"
        echo "Branch: $BRANCH_NAME"
      } > "$body"
      write_result "$TASK_NAME" "$BRANCH_NAME" "$WORKTREE_DIR" "mack-watcher" "FAILED" "$body"
      rm -f "$body"
      budget_increment failures
      archive_task "$TASK_FILE"
      exit 0
    fi
  fi
  cleanup_worktree() {
    git -C "$repo" worktree remove "$WORKTREE_DIR" --force >/dev/null 2>&1 || true
  }
  trap 'cleanup_worktree; rm -rf "$LOCKDIR"' EXIT
else
  WORKTREE_DIR="$repo"
  BRANCH_NAME="n/a"
fi

budget_increment runs

# ── Memory injection (Upgrade 3) — passed to mack-runner.sh via env vars ──
AGENT_DOMAIN="fieldvision"
DOMAIN_MEMORY=$(query_memory "$AGENT_DOMAIN" "" 20 2>/dev/null || true)
SYSTEM_MEMORY=$(query_memory "system" "" 10 2>/dev/null || true)
export DOMAIN_MEMORY SYSTEM_MEMORY
[[ -n "$DOMAIN_MEMORY" ]] && log "Memory: domain_knowledge ($(printf '%s' "$DOMAIN_MEMORY" | wc -l | tr -d ' ') lines, domain=$AGENT_DOMAIN)"
[[ -n "$SYSTEM_MEMORY" ]] && log "Memory: system_knowledge ($(printf '%s' "$SYSTEM_MEMORY" | wc -l | tr -d ' ') lines)"

TMP_OUT=$(mktemp)
TMP_ERR=$(mktemp)
ENGINE_USED="none"
RUN_RC=1

if preflight_check; then
  if "$RUNNER" claude "$WORKTREE_DIR" "$TASK_FILE" "$timeout_secs" mack-autonomous >"$TMP_OUT" 2>"$TMP_ERR"; then
    ENGINE_USED="claude-code:claude-opus-4-6"
    RUN_RC=0
  else
    RUN_RC=$?
  fi
fi

if [[ "$RUN_RC" -eq 0 && "$USE_WORKTREE" == "true" ]]; then
  if ! git -C "$WORKTREE_DIR" diff --quiet || ! git -C "$WORKTREE_DIR" diff --cached --quiet; then
    git -C "$WORKTREE_DIR" add -A >/dev/null 2>&1 || true
    git -C "$WORKTREE_DIR" commit -m "mack: ${TASK_NAME}" >/dev/null 2>&1 || true
  fi
  # Persist worktree: merge branch back into main repo so work survives cleanup
  if git -C "$repo" rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    CURRENT_BRANCH=$(git -C "$repo" branch --show-current 2>/dev/null || echo "main")
    if git -C "$repo" merge "$BRANCH_NAME" --no-edit -m "merge mack: ${TASK_NAME}" >/dev/null 2>&1; then
      log "Merged $BRANCH_NAME back into $CURRENT_BRANCH"
    else
      # Merge conflict — keep the branch alive, skip cleanup
      git -C "$repo" merge --abort >/dev/null 2>&1 || true
      MERGE_CONFLICT=true
      log "WARNING: merge conflict on $BRANCH_NAME — branch preserved, worktree kept"
      trap 'rm -rf "$LOCKDIR"' EXIT  # Override cleanup to keep worktree
    fi
  fi
fi

VALIDATION="PASS"
if [[ "${MERGE_CONFLICT:-}" == "true" ]]; then
  VALIDATION="MERGE_CONFLICT"
elif [[ "$RUN_RC" -eq 124 ]]; then
  VALIDATION="TIMEOUT"
elif [[ "$RUN_RC" -eq 43 ]]; then
  VALIDATION="CONTEXT_OVERFLOW"
elif [[ "$RUN_RC" -ne 0 ]]; then
  VALIDATION="FAILED"
fi

BODY=$(mktemp)
{
  echo "Task: $TASK_NAME"
  echo "Repo: $repo"
  echo "Branch: $BRANCH_NAME"
  echo "Worktree: $WORKTREE_DIR"
  echo "Timeout: ${timeout_secs}s"
  echo
  echo "## Output"
  if [[ -s "$TMP_OUT" ]]; then
    cat "$TMP_OUT"
  else
    echo "(no output captured)"
  fi
  if [[ -s "$TMP_ERR" ]]; then
    echo
    echo "## Stderr"
    tail -n 80 "$TMP_ERR"
  fi
} > "$BODY"

if [[ "$VALIDATION" != "PASS" ]]; then
  budget_increment failures
fi

# ── Output fingerprint scan (passive — log only, no blocking) ─────────────────
OUTPUT_SCANNER="$HOME/.myndaix/bridge/scripts/scan-output.sh"
if [[ -x "$OUTPUT_SCANNER" ]] && [[ -s "$TMP_OUT" ]]; then
  "$OUTPUT_SCANNER" "$TMP_OUT" --agent mack --task-id "${task_id:-$TASK_NAME}" 2>> "$LOG" || true
fi

write_result "$TASK_NAME" "$BRANCH_NAME" "$WORKTREE_DIR" "$ENGINE_USED" "$VALIDATION" "$BODY"

# ── Mandatory Oracle review (async, non-blocking) ────────────────────────────
ORACLE_DISPATCH="$HOME/.myndaix/bridge/scripts/dispatch-oracle-review.sh"
if [[ -x "$ORACLE_DISPATCH" ]] && [[ "$VALIDATION" == "PASS" ]]; then
  "$ORACLE_DISPATCH" mack "$TASK_NAME" "$repo" "$BRANCH_NAME" "$WORKTREE_DIR" "$BODY" >> "$LOG" 2>&1 || true
  log "Oracle review dispatched for $TASK_NAME"
fi

# ── Context checkpoint (Phase 1: 10x Production Plan) ─────────────────────────
CHECKPOINT_SCRIPT="$HOME/.myndaix/bridge/scripts/write-checkpoint.sh"
if [[ -x "$CHECKPOINT_SCRIPT" ]]; then
  "$CHECKPOINT_SCRIPT" \
    --agent mack \
    --topic "${subject:-$TASK_NAME}" \
    --completed "${subject:-$TASK_NAME}" \
    --decisions "engine=$ENGINE_USED validation=$VALIDATION" \
    --next "awaiting next dispatch" \
    --task-id "${task_id:-}" \
    >> "$LOG" 2>&1 || true
fi

# ── Completion signal (Phase 2 prep: auto-dispatch verification) ──────────────
COMPLETION_SCRIPT="$HOME/.myndaix/bridge/scripts/write-completion.sh"
if [[ -x "$COMPLETION_SCRIPT" ]]; then
  "$COMPLETION_SCRIPT" \
    --agent mack \
    --task-id "${task_id:-$TASK_NAME}" \
    --task-name "${subject:-$TASK_NAME}" \
    --result "$VALIDATION" \
    --repo "$repo" \
    --branch "$BRANCH_NAME" \
    >> "$LOG" 2>&1 || true
fi

# --- Agent-to-agent dispatch: forward if dispatch_to is set ---
dispatch_to=$(json_get "$frontmatter_json" "dispatch_to")
if [[ -n "$dispatch_to" && "$VALIDATION" == "PASS" ]]; then
  DISPATCH_SCRIPT="$HOME/.myndaix/bridge/scripts/agent-dispatch.sh"
  if [[ -x "$DISPATCH_SCRIPT" ]]; then
    if "$DISPATCH_SCRIPT" "$dispatch_to" "$TASK_FILE" "mack" "$BRANCH_NAME" >> "$LOG" 2>&1; then
      log "Forwarded task to $dispatch_to via agent-dispatch (chain continues)"
    else
      log "WARNING: agent-dispatch to $dispatch_to failed (rc=$?)"
    fi
  else
    log "WARNING: agent-dispatch.sh not found or not executable"
  fi
fi

rm -f "$BODY" "$TMP_OUT" "$TMP_ERR"
write_heartbeat "$TASK_NAME" "$VALIDATION"
archive_task "$TASK_FILE"
log_task "${task_id:-${TASK_NAME%.md}}" "mack" "task" "$(echo "$VALIDATION" | tr '[:upper:]' '[:lower:]')" "$ENGINE_USED"
check_pain "${AGENT_NAME}" 2>/dev/null || true
# Close SQLite task if claimed (Upgrade 5)
if [ "${CLAIM_SOURCE:-}" = "sqlite" ] && [ -n "${TASK_ID:-}" ]; then
  _tq_status="failed"
  case "${VALIDATION:-${STATUS:-}}" in
    PASS|pass|success|completed|SUCCESS|COMPLETED) _tq_status="success" ;;
  esac
  complete_task "$TASK_ID" "$_tq_status" "${VALIDATION:-${STATUS:-}}" "" "" 2>/dev/null || true
fi

# Pattern detection (Upgrade 6) — fires after success or failure
if [ "${VALIDATION:-}" = "PASS" ] || [ "${STATUS:-}" = "success" ]; then
  detect_pattern "${AGENT_NAME:-unknown}" "${task_type:-task}" "${subject:-${objective:-unknown}}" "${repo:-}" "${task_id:-${TASK_NAME%.md}}" 2>/dev/null || true
else
  detect_failure_pattern "${AGENT_NAME:-unknown}" "${task_type:-task}" "${subject:-${objective:-unknown}}" "${repo:-}" "${task_id:-${TASK_NAME%.md}}" "${VALIDATION:-${STATUS:-failed}}" 2>/dev/null || true
fi
log "Completed task: $TASK_NAME (validation=$VALIDATION, engine=$ENGINE_USED)"
