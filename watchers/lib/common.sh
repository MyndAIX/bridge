#!/bin/bash
# common.sh — shared watcher functions
# Source this AFTER setting: AGENT_NAME, INBOX, OUTBOX, PROCESSED, LOG, LOCKDIR, STALE_LOCK_SECS
# Optional: WRITE_ACK="true" to enable .ack file delivery confirmation

# ── Guard: required variables ──
for _var in AGENT_NAME INBOX OUTBOX PROCESSED LOG LOCKDIR STALE_LOCK_SECS; do
  if [[ -z "${!_var:-}" ]]; then
    echo "FATAL: common.sh requires \$$_var to be set" >&2
    exit 1
  fi
done
unset _var

# ── Logging ──

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT_NAME] $*" >> "$LOG"
}

iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ── String utilities ──

safe_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-48
}

# Sanitize a string for safe YAML scalar interpolation (strip newlines, escape quotes)
_sanitize_yaml() {
  local val="$1"
  val="${val//$'\n'/ }"
  val="${val//$'\r'/}"
  val="${val//\"/\\\"}"
  printf '%s' "$val"
}

# Safely encode a value for JSON string (escape quotes, backslashes, newlines)
_json_encode() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  val="${val//$'\n'/\\n}"
  val="${val//$'\r'/}"
  val="${val//$'\t'/\\t}"
  printf '%s' "$val"
}

# ── Telemetry ──

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

  local _tid _agent _type _status _model _error
  _tid="$(_json_encode "$task_id")"
  _agent="$(_json_encode "$agent")"
  _type="$(_json_encode "$type")"
  _status="$(_json_encode "$task_status")"
  _model="$(_json_encode "$model")"
  _error="$(_json_encode "$error")"

  printf '{"task_id":"%s","agent":"%s","type":"%s","status":"%s","model":"%s","tokens_in":%s,"tokens_out":%s,"error":"%s","timestamp":"%s"}\n' \
    "$_tid" "$_agent" "$_type" "$_status" "$_model" "$tokens_in" "$tokens_out" "$_error" "$timestamp" \
    >> "$HOME/.myndaix/telemetry/tasks.jsonl"
}

# ── Task selection ──

pick_oldest_task() {
  ls -1tr "$INBOX"/*.md 2>/dev/null | grep -v -e '\.tmp' -e '~syncthing~' -e '\.syncthing\.' | head -n 1 || true
}

archive_task() {
  local task_file="$1"
  local task_name
  task_name=$(basename "$task_file")
  local tmp_name="${task_file}.archived"
  mv "$task_file" "$tmp_name" 2>/dev/null || return 0
  local target="$PROCESSED/$task_name"
  if [[ -e "$target" ]]; then
    target="$PROCESSED/$(date -u '+%Y%m%d%H%M%S')-$task_name"
  fi
  mv "$tmp_name" "$target"
}

# ── Locking ──

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
      local old_pid old_cmd
      old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
      if [[ -n "$old_pid" && "$old_pid" =~ ^[0-9]+$ ]]; then
        # Validate process is actually a watcher before killing
        old_cmd=$(ps -p "$old_pid" -o comm= 2>/dev/null || echo "")
        if [[ "$old_cmd" == "bash" || "$old_cmd" == "zsh" ]]; then
          kill "$old_pid" 2>/dev/null || true
        else
          log "WARN: stale lock PID $old_pid is '$old_cmd', not a shell — skipping kill"
        fi
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

release_lock() {
  rm -rf "$LOCKDIR"
}

# ── Heartbeat ──

write_heartbeat() {
  local task_name="${1:-unknown}"
  local result="${2:-unknown}"
  local state_file="$HOME/.myndaix/bridge/state/${AGENT_NAME}-heartbeat.json"
  mkdir -p "$(dirname "$state_file")"
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
    pass|success|completed|failed|skipped|timeout|rejected|context_overflow)
      today_count=$((today_count + 1))
      ;;
  esac

  local _agent _task _res
  _agent="$(_json_encode "$AGENT_NAME")"
  _task="$(_json_encode "$task_name")"
  _res="$(_json_encode "$result")"
  printf '{"agent":"%s","last_beat":"%s","date":"%s","last_task":"%s","last_result":"%s","tasks_today":%d}\n' \
    "$_agent" "$now" "$today" "$_task" "$_res" "$today_count" > "$state_file"

  # ── Outcome tracking (learning loop) ──
  local outcomes_file="$HOME/.myndaix/memory/outcomes.csv"
  mkdir -p "$(dirname "$outcomes_file")"
  if [[ ! -f "$outcomes_file" ]]; then
    echo "timestamp,agent,task,result,tasks_today" > "$outcomes_file"
  fi
  echo "$now,$AGENT_NAME,$_task,$_res,$today_count" >> "$outcomes_file"
}

# ── Result writing ──
# Two calling conventions:
#   Simple  (4 args): write_result subject status engine body_file
#   Builder (6 args): write_result subject branch worktree engine validation body_file

write_result() {
  local ts
  ts=$(date -u '+%Y%m%d%H%M%S')
  local out="$OUTBOX/${ts}-${AGENT_NAME}-result.md"

  if [[ $# -eq 4 ]]; then
    # Simple mode (harley, recon)
    local subject status engine body_file
    subject="$(_sanitize_yaml "$1")"
    status="$(_sanitize_yaml "$2")"
    engine="$(_sanitize_yaml "$3")"
    body_file="$4"
    {
      echo "---"
      echo "type: result"
      echo "from: $AGENT_NAME"
      echo "to: lobster"
      echo "subject: \"Re: ${subject}\""
      echo "status: ${status}"
      echo "engine: ${engine}"
      echo "created: $(iso_now)"
      [ -n "${task_id:-}" ] && echo "task_id: $(_sanitize_yaml "${task_id}")"
      echo "---"
      echo
      cat "$body_file"
    } > "$out"
    log "Wrote result: $out (status=$status)"
  elif [[ $# -eq 6 ]]; then
    # Builder mode (antman, kilabz, mini, oracle)
    local subject branch worktree engine validation body_file
    subject="$(_sanitize_yaml "$1")"
    branch="$(_sanitize_yaml "$2")"
    worktree="$(_sanitize_yaml "$3")"
    engine="$(_sanitize_yaml "$4")"
    validation="$(_sanitize_yaml "$5")"
    body_file="$6"
    {
      echo "---"
      echo "from: $AGENT_NAME"
      echo "to: lobster"
      echo "type: result"
      echo "subject: \"Re: ${subject}\""
      echo "branch: ${branch}"
      echo "worktree: ${worktree}"
      echo "engine: ${engine}"
      echo "validation: ${validation}"
      # verdict is the code-review outcome (PASS|FAIL), distinct from
      # validation (did the agent itself run correctly). Only kilabz sets it.
      [ -n "${VERDICT:-}" ] && echo "verdict: $(_sanitize_yaml "${VERDICT}")"
      echo "created: $(iso_now)"
      [ -n "${task_id:-}" ] && echo "task_id: $(_sanitize_yaml "${task_id}")"
      echo "---"
      echo
      cat "$body_file"
    } > "$out"
    log "Wrote result: $out (validation=$validation)"
  else
    log "ERROR: write_result called with $# args (expected 4 or 6)"
    return 1
  fi

  # Optional delivery confirmation
  if [[ "${WRITE_ACK:-}" == "true" ]]; then
    local ack_dir="$HOME/.myndaix/bridge/acks"
    mkdir -p "$ack_dir"
    local ack_file="$ack_dir/${ts}-${AGENT_NAME}.ack"
    local _a _t _v _r _ts
    _a="$(_json_encode "$AGENT_NAME")"
    _r="$(_json_encode "$(basename "$out")")"
    _ts="$(iso_now)"
    if [[ $# -eq 4 ]]; then
      _t="$(_json_encode "$1")"
      _v="$(_json_encode "$2")"
      printf '{"agent":"%s","task":"%s","status":"%s","result":"%s","ts":"%s"}\n' \
        "$_a" "$_t" "$_v" "$_r" "$_ts" > "$ack_file"
    else
      _t="$(_json_encode "$1")"
      _v="$(_json_encode "$5")"
      printf '{"agent":"%s","task":"%s","validation":"%s","result":"%s","ts":"%s"}\n' \
        "$_a" "$_t" "$_v" "$_r" "$_ts" > "$ack_file"
    fi
  fi
}

reject_task() {
  local task_name="$1" reason="$2"
  local body
  body=$(mktemp)
  {
    echo "Task rejected by fail-closed validation."
    echo
    echo "Reason: $reason"
    echo "Task: $task_name"
  } > "$body"
  # Use builder-style if REJECT_STYLE is "builder", else simple
  if [[ "${REJECT_STYLE:-simple}" == "builder" ]]; then
    write_result "$task_name" "n/a" "n/a" "${AGENT_NAME}-watcher" "REJECTED" "$body"
  else
    write_result "$task_name" "failed" "${AGENT_NAME}-watcher" "$body"
  fi
  rm -f "$body"
}

# ── Frontmatter parsing ──

parse_frontmatter_json() {
  local file="$1"
  ruby -Eutf-8 -ryaml -rjson -rdate -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
    abort("missing_frontmatter") unless m
    data = YAML.safe_load(m[1], permitted_classes: [Date, Time], aliases: false)
    abort("frontmatter_not_map") unless data.is_a?(Hash)
    puts JSON.generate(data)
  ' "$file"
}

json_get() {
  local json="$1" key="$2"
  ruby -Eutf-8 -rjson -e '
    data = JSON.parse(ARGV[0])
    val = data[ARGV[1]]
    if val.nil?
      puts ""
    elsif val.is_a?(String) || val.is_a?(Numeric) || val == true || val == false
      puts val.to_s
    else
      puts val.to_json
    end
  ' "$json" "$key"
}

get_body() {
  local file="$1"
  ruby -Eutf-8 -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n.*?\n---\s*\n(.*)\z/m)
    puts m ? m[1].strip : ""
  ' "$file" 2>/dev/null || echo ""
}

extract_context_paths() {
  local file="$1"
  ruby -Eutf-8 -ryaml -rdate -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
    exit 0 unless m
    data = YAML.safe_load(m[1], permitted_classes: [Date, Time], aliases: false)
    exit 0 unless data.is_a?(Hash)

    keys = %w[attachments context_files files]
    paths = []
    keys.each do |k|
      v = data[k]
      case v
      when String
        paths << v
      when Array
        v.each { |i| paths << i if i.is_a?(String) }
      end
    end

    paths.uniq.each { |p| puts p }
  ' "$file" 2>/dev/null || true
}

# ── Timeout execution ──

# Run a command with timeout. CALLER MUST ensure $cmd is built from trusted/validated tokens only.
# Do NOT pass untrusted task content as part of $cmd — use stdin/files instead.
run_with_timeout_cmd() {
  local secs="$1"
  local cmd="$2"
  # Run in new process group for clean cleanup
  /bin/bash -lc "exec perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV' -- /bin/bash -lc $(printf '%q' "$cmd")" &
  local pid=$!
  (
    sleep "$secs"
    # Kill entire process group
    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -- -"$pgid" 2>/dev/null || true
      sleep 5
      kill -KILL -- -"$pgid" 2>/dev/null || true
    else
      kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) &
  local watchdog=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  if [[ "$rc" -eq 137 || "$rc" -eq 143 ]]; then
    rc=124
  fi
  return "$rc"
}

# ── Schema validation (Upgrade 2) ──
# Required fields per task contract: from, to, type, subject
# Valid types: task | review | research | creative
# On failure: log to telemetry, move to rejected/, return 1.
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
  task_type=$(grep "^type:" "$task_file" | head -1 | awk '{print $2}' | tr -d '\"' | tr -d "'")
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

# ── Pain response / Circuit breaker (Upgrade 2) ──
# Counts "failed" entries for an agent in tasks.jsonl within the last hour.
# If >= threshold, writes pause file + alerts lobster. Idempotent (no-op if already paused).
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

# ── Memory query/save (Upgrade 3 Part 1) ──
# Reads/writes ~/.myndaix/memory.db. Schema in memory.db.
# Side effect of query_memory: bumps last_accessed and access_count for returned rows.

query_memory() {
    local domain="$1"
    local category="${2:-}"
    local limit="${3:-20}"

    local where="WHERE deprecated=0 AND domain='$domain'"
    if [ -n "$category" ]; then
        where="$where AND category='$category'"
    fi

    sqlite3 ~/.myndaix/memory.db \
        "UPDATE memory SET last_accessed=datetime('now'), access_count=access_count+1
         WHERE id IN (SELECT id FROM memory $where ORDER BY confidence DESC, last_accessed DESC LIMIT $limit);
         SELECT content FROM memory $where ORDER BY confidence DESC, last_accessed DESC LIMIT $limit"
}

save_memory() {
    local domain="$1"
    local category="$2"
    local content="$3"
    local evidence="${4:-}"
    local task_id="${5:-}"
    local tags="${6:-}"

    local safe_content=$(echo "$content" | sed "s/'/''/g")
    local safe_evidence=$(echo "$evidence" | sed "s/'/''/g")

    sqlite3 ~/.myndaix/memory.db \
        "INSERT INTO memory (domain, category, content, evidence, source_task_id, tags, last_accessed)
         VALUES ('$domain', '$category', '$safe_content', '$safe_evidence', '$task_id', '$tags', datetime('now'))"
}

# ── Task queue (Upgrade 5) ──
# Backed by ~/.myndaix/memory.db tasks table. Runs in parallel with file-based inbox.

_task_id_gen() {
  printf 'TASK-%s-%s' "$(date +%s)" "$(openssl rand -hex 4 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(4))')"
}

# dispatch_task <target> <type> <priority> <objective> <body> <branch> <sender> <inbox_file>
# Inserts row with status=queued. Logs telemetry. Outputs task_id on stdout.
dispatch_task() {
  local target="$1" type="$2" priority="${3:-5}" objective="$4" body="$5" branch="$6" sender="$7" inbox_file="${8:-}"
  local task_id
  task_id=$(_task_id_gen)
  local _obj _body _branch _ifile
  _obj=$(printf '%s' "$objective" | sed "s/'/''/g")
  _body=$(printf '%s' "$body" | sed "s/'/''/g")
  _branch=$(printf '%s' "$branch" | sed "s/'/''/g")
  _ifile=$(printf '%s' "$inbox_file" | sed "s/'/''/g")
  if sqlite3 "$HOME/.myndaix/memory.db" \
    "INSERT INTO tasks (id, type, agent, priority, status, objective, body, branch, dispatched_by, inbox_file)
     VALUES ('$task_id', '$type', '$target', $priority, 'queued', '$_obj', '$_body', '$_branch', '$sender', '$_ifile')" 2>/dev/null; then
    log_task "$task_id" "$target" "$type" "dispatched" "queue" 0 0 "from:$sender"
    printf '%s\n' "$task_id"
    return 0
  fi
  return 1
}

# claim_task <agent> — atomic claim using UPDATE+subquery+RETURNING (single statement)
# Output: id|type|objective|body|branch|inbox_file  (empty if nothing queued)
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

# complete_task <task_id> <status> [result_summary] [result_path] [error]
# success/completed → mark completed; failed → retry or dead-letter
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
      rc_max=$(sqlite3 "$HOME/.myndaix/memory.db" \
        "SELECT retry_count || '|' || max_retries FROM tasks WHERE id='$_id'" 2>/dev/null)
      [ -z "$rc_max" ] && return 1
      rc=$(printf '%s' "$rc_max" | cut -d'|' -f1)
      max=$(printf '%s' "$rc_max" | cut -d'|' -f2)
      if [ "$rc" -lt "$max" ]; then
        sqlite3 "$HOME/.myndaix/memory.db" \
          "UPDATE tasks SET status='queued', claimed_at=NULL, retry_count=retry_count+1, error='$_err' WHERE id='$_id'"
        log_task "$task_id" "queue" "task" "retry" "queue" 0 0 "$_err"
      else
        sqlite3 "$HOME/.myndaix/memory.db" \
          "UPDATE tasks SET status='failed', completed_at=datetime('now'), error='$_err' WHERE id='$_id'"
        log_task "$task_id" "queue" "task" "dead_letter" "queue" 0 0 "$_err"
      fi
      ;;
  esac
}

daily_summary() {
  sqlite3 -header -column "$HOME/.myndaix/memory.db" \
    "SELECT agent, status, COUNT(*) AS n FROM tasks
     WHERE dispatched_at > datetime('now','-24 hours')
     GROUP BY agent, status ORDER BY agent, status"
}

dead_letters() {
  sqlite3 -header -column "$HOME/.myndaix/memory.db" \
    "SELECT id, agent, retry_count, substr(error,1,60) AS error_preview, completed_at FROM tasks
     WHERE status='failed' AND retry_count >= max_retries
     ORDER BY completed_at DESC"
}

agent_queue() {
  local agent="$1"
  local _a
  _a=$(printf '%s' "$agent" | sed "s/'/''/g")
  sqlite3 -header -column "$HOME/.myndaix/memory.db" \
    "SELECT id, priority, dispatched_at, retry_count FROM tasks
     WHERE agent='$_a' AND status='queued' ORDER BY priority ASC, dispatched_at ASC"
}

# ── Pattern detection + promotion (Upgrade 6) ──
# Backed by patterns table in ~/.myndaix/memory.db.
# detect_pattern: UPSERT, increment, propose at threshold=3
# detect_failure_pattern: UPSERT only, no proposal
# approve_pattern / reject_pattern: external (Lobster/Jefe approval flow)

# Internal: generate keyword-based fingerprint
_pattern_fingerprint() {
  local agent="$1" type="$2" objective="$3" repo="$4"
  python3 -c "
import hashlib, re, sys
STOPWORDS = {'the','and','for','with','from','that','this','into','have','but','not','your','what','will','also','now','get','task','review','please'}
agent, ttype, objective, repo = sys.argv[1:5]
tokens = sorted({tok for tok in re.findall(r'[a-z]+', objective.lower())
                 if tok not in STOPWORDS and len(tok) >= 3})
keywords = sorted(sorted(tokens, key=len, reverse=True)[:3])
raw = f'{agent}|{ttype}|{repo or \"*\"}|{\"|\".join(keywords)}'
print(hashlib.sha256(raw.encode()).hexdigest()[:16])
" "$agent" "$type" "$objective" "$repo" 2>/dev/null
}

# Recommended promotion type by agent
_pattern_recommend_type() {
  case "$1" in
    kilabz|oracle) echo "lint_rule" ;;
    recon|harley) echo "template" ;;
    mini|mack|antman) echo "prompt_improvement" ;;
    *) echo "prompt_improvement" ;;
  esac
}

# detect_pattern <agent> <type> <objective> <repo> <task_id>
# Inserts new pattern or increments existing. On 3rd occurrence not yet proposed,
# writes a proposal to the configured lobster inbox and marks proposal_sent_at.
detect_pattern() {
  local agent="$1" type="$2" objective="$3" repo="$4" task_id="$5"
  local fp
  fp=$(_pattern_fingerprint "$agent" "$type" "$objective" "$repo")
  [ -z "$fp" ] && return 1

  local rec_type
  rec_type=$(_pattern_recommend_type "$agent")

  local _agent _type _rec _fp _tid _desc
  _agent=$(printf '%s' "$agent" | sed "s/'/''/g")
  _type=$(printf '%s' "$type" | sed "s/'/''/g")
  _rec=$(printf '%s' "$rec_type" | sed "s/'/''/g")
  _fp=$(printf '%s' "$fp" | sed "s/'/''/g")
  _tid=$(printf '%s' "$task_id" | sed "s/'/''/g")
  _desc=$(printf '%s' "$objective" | head -c 200 | sed "s/'/''/g")

  local existing
  existing=$(sqlite3 "$HOME/.myndaix/memory.db" \
    "SELECT id FROM patterns WHERE fingerprint='$_fp'" 2>/dev/null)

  if [ -z "$existing" ]; then
    sqlite3 "$HOME/.myndaix/memory.db" \
      "INSERT INTO patterns (pattern_type, description, fingerprint, occurrences, agent, recommended_type, evidence_task_ids)
       VALUES ('success', '$_desc', '$_fp', 1, '$_agent', '$_rec', '$_tid')" 2>/dev/null
    return 0
  fi

  sqlite3 "$HOME/.myndaix/memory.db" \
    "UPDATE patterns SET
       occurrences = occurrences + 1,
       last_seen = datetime('now'),
       evidence_task_ids = COALESCE(evidence_task_ids || ',', '') || '$_tid'
     WHERE fingerprint='$_fp'" 2>/dev/null

  # Read current state to decide whether to propose
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

A pattern has been detected $occ times and meets the promotion threshold.

**Pattern ID:** $pid
**Fingerprint:** $fp
**Agent:** $agent_v
**Description:** $desc
**Recommended type:** $rec_v
**Evidence task IDs:** $evid

Approve: \`approve_pattern $pid\`
Reject:  \`reject_pattern $pid\`

(automated proposal at $(date -u +%Y-%m-%dT%H:%M:%SZ))
PROPOSAL_EOF
    sqlite3 "$HOME/.myndaix/memory.db" \
      "UPDATE patterns SET proposal_sent_at = datetime('now') WHERE id=$pid"
    log_task "PATTERN-$pid" "$agent_v" "pattern" "proposed" "auto" 0 0 "occ=$occ rec=$rec_v"
  fi
  return 0
}

# detect_failure_pattern <agent> <type> <objective> <repo> <task_id> <error>
# Same shape as detect_pattern but pattern_type='failure', NEVER proposes promotion.
detect_failure_pattern() {
  local agent="$1" type="$2" objective="$3" repo="$4" task_id="$5" error="${6:-}"
  local fp
  fp=$(_pattern_fingerprint "$agent" "$type" "$objective" "$repo")
  [ -z "$fp" ] && return 1
  fp="F$fp"  # prefix to avoid collision with success patterns

  local _agent _type _fp _tid _desc _err
  _agent=$(printf '%s' "$agent" | sed "s/'/''/g")
  _type=$(printf '%s' "$type" | sed "s/'/''/g")
  _fp=$(printf '%s' "$fp" | sed "s/'/''/g")
  _tid=$(printf '%s' "$task_id" | sed "s/'/''/g")
  _desc=$(printf '%s' "$objective" | head -c 200 | sed "s/'/''/g")
  _err=$(printf '%s' "$error" | head -c 100 | sed "s/'/''/g")

  local existing
  existing=$(sqlite3 "$HOME/.myndaix/memory.db" \
    "SELECT id FROM patterns WHERE fingerprint='$_fp'" 2>/dev/null)

  if [ -z "$existing" ]; then
    sqlite3 "$HOME/.myndaix/memory.db" \
      "INSERT INTO patterns (pattern_type, description, fingerprint, occurrences, agent, evidence_task_ids)
       VALUES ('failure', '$_desc [err: $_err]', '$_fp', 1, '$_agent', '$_tid')" 2>/dev/null
  else
    sqlite3 "$HOME/.myndaix/memory.db" \
      "UPDATE patterns SET
         occurrences = occurrences + 1,
         last_seen = datetime('now'),
         evidence_task_ids = COALESCE(evidence_task_ids || ',', '') || '$_tid'
       WHERE fingerprint='$_fp'" 2>/dev/null
  fi
  return 0
}

# approve_pattern <pattern_id> [type_override]
# Marks promoted; for prompt_improvement auto-saves to memory.db at confidence=1.0
approve_pattern() {
  local pid="$1" type_override="${2:-}"
  local row
  row=$(sqlite3 "$HOME/.myndaix/memory.db" \
    "SELECT description, agent, recommended_type FROM patterns WHERE id=$pid AND COALESCE(rejected,0)=0")
  if [ -z "$row" ]; then echo "pattern $pid not found or rejected" >&2; return 1; fi

  local desc agent rec_type
  desc=$(echo "$row" | cut -d'|' -f1)
  agent=$(echo "$row" | cut -d'|' -f2)
  rec_type=$(echo "$row" | cut -d'|' -f3)
  local final_type="${type_override:-$rec_type}"

  sqlite3 "$HOME/.myndaix/memory.db" \
    "UPDATE patterns SET promoted=1, promoted_to='$final_type', promoted_at=datetime('now'),
            approved_at=datetime('now'), approved_by='${APPROVED_BY:-jefe}'
     WHERE id=$pid"

  if [ "$final_type" = "prompt_improvement" ]; then
    local domain
    case "$agent" in
      recon) domain="research" ;;
      harley) domain="marketing" ;;
      *) domain="fieldvision" ;;
    esac
    local _content _evid
    _content=$(printf '%s' "$desc" | sed "s/'/''/g")
    _evid=$(printf '%s' "promoted from pattern $pid" | sed "s/'/''/g")
    sqlite3 "$HOME/.myndaix/memory.db" \
      "INSERT INTO memory (domain, category, content, evidence, source_task_id, tags, confidence, last_accessed)
       VALUES ('$domain', 'pattern', '$_content', '$_evid', 'PATTERN-$pid', '$agent,promoted', 1.0, datetime('now'))"
    echo "approved + saved to memory.db (domain=$domain, confidence=1.0)"
  else
    local todo_inbox="${PROMOTION_TODO_INBOX:-$HOME/.myndaix/bridge/inbox/lobster}"
    mkdir -p "$todo_inbox"
    local todo="$todo_inbox/promotion-todo-${pid}-$(date +%s).md"
    cat > "$todo" <<TODO_EOF
---
from: pattern-detector
to: lobster
type: alert
subject: "[PROMOTION-TODO] Implement $final_type from pattern $pid"
priority: 3
---

Pattern $pid (agent=$agent) approved.
**Recommended implementation:** $final_type
**Description:** $desc

Implementation hints:
- lint_rule: add to syntax-check.sh or a CI lint job
- hook: add a pre/post tool-use hook in ~/.claude/settings.json
- template: save as reusable prompt template for $agent
- routing_rule: update auto-router.sh logic
- eval_gate: add a test/eval requirement
TODO_EOF
    echo "approved; TODO created at $todo"
  fi
  log_task "PATTERN-$pid" "$agent" "pattern" "promoted" "auto" 0 0 "type=$final_type"
}

# reject_pattern <pattern_id>
reject_pattern() {
  local pid="$1"
  sqlite3 "$HOME/.myndaix/memory.db" \
    "UPDATE patterns SET rejected=1, rejected_at=datetime('now') WHERE id=$pid"
  log_task "PATTERN-$pid" "system" "pattern" "rejected" "auto" 0 0 "manual"
  echo "pattern $pid rejected"
}

pending_proposals() {
  sqlite3 -header -column "$HOME/.myndaix/memory.db" \
    "SELECT id, agent, recommended_type, occurrences, substr(description,1,50) AS description, proposal_sent_at
     FROM patterns
     WHERE pattern_type='success' AND proposal_sent_at IS NOT NULL
       AND COALESCE(promoted,0)=0 AND COALESCE(rejected,0)=0
     ORDER BY proposal_sent_at DESC"
}

failure_patterns() {
  sqlite3 -header -column "$HOME/.myndaix/memory.db" \
    "SELECT id, agent, occurrences, substr(description,1,80) AS description, last_seen
     FROM patterns
     WHERE pattern_type='failure'
     ORDER BY occurrences DESC, last_seen DESC LIMIT 20"
}
