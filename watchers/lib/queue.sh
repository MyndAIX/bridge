#!/usr/bin/env bash
# queue.sh — Overnight build queue library for bridge pipeline
# Provides: enqueue_task, dequeue_next, queue_status, run_queue, queue_report
#
# Usage: source this file from watchers/runners
# Requires: guardrails.sh, chaining.sh, self-healing.sh (auto-sourced)
#
# Queue state lives in ~/.myndaix/bridge/queue/
#   pending/   — tasks awaiting execution
#   running/   — currently executing (locked)
#   completed/ — finished successfully
#   failed/    — finished with errors
#   dead-letter/ — poison tasks (failed 2x)
#
# No side effects on load — all state changes happen inside function calls.

# ---------------------------------------------------------------------------
# Auto-source dependencies
# ---------------------------------------------------------------------------
_QUEUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f _sanitize_id >/dev/null 2>&1; then
  source "$_QUEUE_LIB_DIR/guardrails.sh"
fi
if ! declare -f dispatch_next >/dev/null 2>&1; then
  source "$_QUEUE_LIB_DIR/chaining.sh"
fi
if ! declare -f handle_failure >/dev/null 2>&1; then
  source "$_QUEUE_LIB_DIR/self-healing.sh"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
QUEUE_DIR="${QUEUE_DIR:-${BRIDGE_DIR}/queue}"
QUEUE_PENDING_DIR="${QUEUE_DIR}/pending"
QUEUE_RUNNING_DIR="${QUEUE_DIR}/running"
QUEUE_COMPLETED_DIR="${QUEUE_DIR}/completed"
QUEUE_FAILED_DIR="${QUEUE_DIR}/failed"
QUEUE_DEAD_LETTER_DIR="${QUEUE_DIR}/dead-letter"
QUEUE_REPORTS_DIR="${QUEUE_DIR}/reports"

MAX_QUEUE_DEPTH="${MAX_QUEUE_DEPTH:-20}"
QUEUE_POISON_THRESHOLD="${QUEUE_POISON_THRESHOLD:-2}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _queue_log <message>
_queue_log() {
  if declare -f log >/dev/null 2>&1; then
    log "[queue] $1"
  else
    printf '[%s] [queue] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
  fi
}

# _queue_ensure_dirs — create queue directory structure
_queue_ensure_dirs() {
  mkdir -p "$QUEUE_PENDING_DIR" "$QUEUE_RUNNING_DIR" \
           "$QUEUE_COMPLETED_DIR" "$QUEUE_FAILED_DIR" \
           "$QUEUE_DEAD_LETTER_DIR" "$QUEUE_REPORTS_DIR"
}

# _queue_count <dir> — count files in a queue directory
_queue_count() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    printf '0'
    return
  fi
  local count
  count=$(find "$dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l)
  printf '%s' "${count// /}"
}

# _queue_validate_priority <priority> — validate priority is P0-P3
_queue_validate_priority() {
  local p="$1"
  case "$p" in
    P0|P1|P2|P3) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. enqueue_task
# ---------------------------------------------------------------------------
# enqueue_task <task_id> <priority> <agent> <subject> [task_body_file]
#
# Adds a task to the queue with priority ordering.
# Writes to queue/pending/<priority>-<timestamp>-<task-id>.md
# P0 runs first (sort order: P0 < P1 < P2 < P3).
#
# Returns 0 on success, 1 on error.
# Prints the queued file path to stdout.
enqueue_task() {
  local raw_task_id="$1"
  local priority="$2"
  local agent="$3"
  local subject="$4"
  local body_file="${5:-}"

  # Validate inputs
  if [[ -z "$raw_task_id" || -z "$priority" || -z "$agent" ]]; then
    _queue_log "ERROR: enqueue_task requires task_id, priority, agent"
    return 1
  fi

  if ! _queue_validate_priority "$priority"; then
    _queue_log "ERROR: invalid priority '$priority' — must be P0-P3"
    return 1
  fi

  local task_id
  task_id=$(_sanitize_id "$raw_task_id")
  if [[ -z "$task_id" ]]; then
    _queue_log "ERROR: task_id sanitized to empty string"
    return 1
  fi

  _queue_ensure_dirs

  # Check queue depth
  local current_depth
  current_depth=$(_queue_count "$QUEUE_PENDING_DIR")
  if (( current_depth >= MAX_QUEUE_DEPTH )); then
    _queue_log "ERROR: queue full (${current_depth}/${MAX_QUEUE_DEPTH}) — rejecting task ${task_id}"
    return 1
  fi

  # Sanitize agent and subject for YAML safety
  local safe_agent safe_subject
  safe_agent=$(printf '%s' "$agent" | tr -cd 'a-zA-Z0-9._-')
  safe_subject=$(printf '%s' "$subject" | tr -cd 'a-zA-Z0-9 ._:/-')

  local ts
  ts=$(date -u '+%Y%m%d%H%M%S')
  local filename="${priority}-${ts}-${task_id}.md"
  local filepath="${QUEUE_PENDING_DIR}/${filename}"

  {
    printf '%s\n' "---"
    printf 'task_id: %s\n' "$task_id"
    printf 'priority: %s\n' "$priority"
    printf 'agent: %s\n' "$safe_agent"
    printf 'subject: "%s"\n' "$safe_subject"
    printf 'status: pending\n'
    printf 'enqueued: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "---"
    printf '\n'
  } > "$filepath"

  # Append body from file if provided
  if [[ -n "$body_file" && -f "$body_file" ]]; then
    cat "$body_file" >> "$filepath"
  fi

  _queue_log "Enqueued: ${filename} (depth: $(( current_depth + 1 ))/${MAX_QUEUE_DEPTH})"
  printf '%s' "$filepath"
  return 0
}

# ---------------------------------------------------------------------------
# 2. dequeue_next
# ---------------------------------------------------------------------------
# dequeue_next
#
# Atomically claims the highest-priority pending task.
# Uses mkdir as an atomic lock. Moves from pending/ to running/.
#
# Prints the running task file path to stdout.
# Returns 0 on success, 1 if queue empty or lock contention.
dequeue_next() {
  _queue_ensure_dirs

  # List pending tasks sorted by name (P0 < P1 < P2 < P3, then timestamp FIFO)
  local pending_files
  pending_files=$(find "$QUEUE_PENDING_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)

  if [[ -z "$pending_files" ]]; then
    return 1
  fi

  local task_file
  for task_file in $pending_files; do
    local basename
    basename=$(basename "$task_file")
    local lock_dir="${QUEUE_RUNNING_DIR}/.lock-${basename}"

    # Atomic lock via mkdir
    if mkdir "$lock_dir" 2>/dev/null; then
      # Move to running
      local dest="${QUEUE_RUNNING_DIR}/${basename}"
      if mv "$task_file" "$dest" 2>/dev/null; then
        # Update status and add started timestamp
        local now
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        # Rewrite via temp file — avoids sed portability issues
        local tmp_dest="${dest}.tmp"
        local in_frontmatter=0
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ "$line" == "---" ]]; then
            in_frontmatter=$(( 1 - in_frontmatter ))
            printf '%s\n' "$line"
            continue
          fi
          if (( in_frontmatter )) && [[ "$line" == "status: pending" ]]; then
            printf 'status: running\n'
          elif (( in_frontmatter )) && [[ "$line" == enqueued:* ]]; then
            printf '%s\n' "$line"
            printf 'started: %s\n' "$now"
          else
            printf '%s\n' "$line"
          fi
        done < "$dest" > "$tmp_dest"
        mv "$tmp_dest" "$dest"

        _queue_log "Dequeued: ${basename}"
        printf '%s' "$dest"

        # Clean up lock dir
        rmdir "$lock_dir" 2>/dev/null
        return 0
      else
        # Move failed — clean up lock
        rmdir "$lock_dir" 2>/dev/null
      fi
    fi
    # Lock contention or move failed — try next task
  done

  _queue_log "No tasks could be dequeued (all locked or empty)"
  return 1
}

# ---------------------------------------------------------------------------
# 3. queue_status
# ---------------------------------------------------------------------------
# queue_status
#
# Prints counts: pending, running, completed, failed, dead-lettered.
# Output format: key=value lines (parseable).
# Returns 0 always.
queue_status() {
  _queue_ensure_dirs

  local pending running completed failed dead_lettered
  pending=$(_queue_count "$QUEUE_PENDING_DIR")
  running=$(_queue_count "$QUEUE_RUNNING_DIR")
  completed=$(_queue_count "$QUEUE_COMPLETED_DIR")
  failed=$(_queue_count "$QUEUE_FAILED_DIR")
  dead_lettered=$(_queue_count "$QUEUE_DEAD_LETTER_DIR")

  printf 'pending=%s\n' "$pending"
  printf 'running=%s\n' "$running"
  printf 'completed=%s\n' "$completed"
  printf 'failed=%s\n' "$failed"
  printf 'dead_lettered=%s\n' "$dead_lettered"
  return 0
}

# ---------------------------------------------------------------------------
# 4. run_queue
# ---------------------------------------------------------------------------
# run_queue <dispatch_fn>
#
# Main loop: dequeue → dispatch → wait for result → chain if needed → repeat.
#
# <dispatch_fn> is a function name the caller provides. It receives:
#   dispatch_fn <task_file>
# and must return 0 on success, non-zero on failure.
# On success, it should write a result file at <task_file>.result
#
# Poison detection: if the same task_id fails QUEUE_POISON_THRESHOLD times,
# it's moved to the dead-letter queue.
#
# Returns 0 when queue is empty, 1 on fatal error.
run_queue() {
  local dispatch_fn="$1"

  if [[ -z "$dispatch_fn" ]] || ! declare -f "$dispatch_fn" >/dev/null 2>&1; then
    _queue_log "ERROR: run_queue requires a valid dispatch function name"
    return 1
  fi

  _queue_ensure_dirs

  local queue_start_ts
  queue_start_ts=$(date +%s)
  local tasks_completed=0
  local tasks_failed=0

  _queue_log "Starting queue run"

  while true; do
    local task_file
    task_file=$(dequeue_next)
    if [[ -z "$task_file" ]]; then
      _queue_log "Queue empty — run complete"
      break
    fi

    local basename
    basename=$(basename "$task_file")

    # Extract task_id from filename: <priority>-<timestamp>-<task_id>.md
    local task_id
    task_id=$(printf '%s' "$basename" | sed 's/^P[0-3]-[0-9]*-//' | sed 's/\.md$//')
    task_id=$(_sanitize_id "$task_id")

    local task_start_ts
    task_start_ts=$(date +%s)

    _queue_log "Processing: ${basename} (task_id=${task_id})"

    # Dispatch the task
    local dispatch_exit=0
    "$dispatch_fn" "$task_file" || dispatch_exit=$?

    local task_end_ts
    task_end_ts=$(date +%s)
    local task_duration=$(( task_end_ts - task_start_ts ))

    if (( dispatch_exit == 0 )); then
      # Success — move to completed
      local dest="${QUEUE_COMPLETED_DIR}/${basename}"
      mv "$task_file" "$dest" 2>/dev/null

      # Append timing metadata
      printf '\n<!-- duration_seconds: %s -->\n' "$task_duration" >> "$dest"

      tasks_completed=$(( tasks_completed + 1 ))
      _queue_log "Completed: ${basename} (${task_duration}s)"

      # Check for chaining — look for result file
      local result_file="${task_file}.result"
      if [[ -f "$result_file" ]]; then
        dispatch_next "$result_file" || true
      fi
    else
      # Failure — check poison threshold
      local fail_count_dir="${QUEUE_DIR}/.fail-counts"
      mkdir -p "$fail_count_dir"
      local fail_count_file="${fail_count_dir}/${task_id}.count"

      local current_fails=0
      if [[ -f "$fail_count_file" ]]; then
        current_fails=$(cat "$fail_count_file")
        if ! [[ "$current_fails" =~ ^[0-9]+$ ]]; then
          current_fails=0
        fi
      fi
      current_fails=$(( current_fails + 1 ))
      printf '%s' "$current_fails" > "$fail_count_file"

      if (( current_fails >= QUEUE_POISON_THRESHOLD )); then
        # Poison task — move to dead-letter
        _queue_log "POISON: ${basename} failed ${current_fails}x — dead-lettering"
        local dl_dest="${QUEUE_DEAD_LETTER_DIR}/${basename}"
        mv "$task_file" "$dl_dest" 2>/dev/null
        printf 'Failed %s times (poison threshold: %s). Exit code: %s\n' \
          "$current_fails" "$QUEUE_POISON_THRESHOLD" "$dispatch_exit" \
          > "${dl_dest}.reason"
        rm -f "$fail_count_file"
      else
        # Regular failure — move to failed, may re-enqueue
        local dest="${QUEUE_FAILED_DIR}/${basename}"
        mv "$task_file" "$dest" 2>/dev/null
        printf '\n<!-- failure_exit_code: %s, duration_seconds: %s -->\n' \
          "$dispatch_exit" "$task_duration" >> "$dest"

        _queue_log "Failed: ${basename} (exit=${dispatch_exit}, ${task_duration}s, fails=${current_fails}/${QUEUE_POISON_THRESHOLD})"

        # Use self-healing for retry logic
        local error_ctx="Task dispatch failed with exit code ${dispatch_exit}"
        local failure_code
        failure_code=$(classify_failure "$dispatch_exit" "$error_ctx")
        handle_failure "$task_id" "$failure_code" "$error_ctx" "$dest" || true
      fi

      tasks_failed=$(( tasks_failed + 1 ))
    fi
  done

  local queue_end_ts
  queue_end_ts=$(date +%s)
  local total_duration=$(( queue_end_ts - queue_start_ts ))

  _queue_log "Queue run finished: ${tasks_completed} completed, ${tasks_failed} failed, ${total_duration}s total"
  return 0
}

# ---------------------------------------------------------------------------
# 5. queue_report
# ---------------------------------------------------------------------------
# queue_report
#
# Generates a morning summary of all queue results.
# Writes report to queue/reports/<date>-report.md
# Prints the report to stdout.
# Returns 0.
queue_report() {
  _queue_ensure_dirs

  local report_date
  report_date=$(date '+%Y-%m-%d')
  local report_file="${QUEUE_REPORTS_DIR}/${report_date}-report.md"

  local pending running completed failed dead_lettered
  pending=$(_queue_count "$QUEUE_PENDING_DIR")
  running=$(_queue_count "$QUEUE_RUNNING_DIR")
  completed=$(_queue_count "$QUEUE_COMPLETED_DIR")
  failed=$(_queue_count "$QUEUE_FAILED_DIR")
  dead_lettered=$(_queue_count "$QUEUE_DEAD_LETTER_DIR")

  local total=$(( completed + failed + dead_lettered ))

  {
    printf '%s\n' "---"
    printf 'type: queue-report\n'
    printf 'date: %s\n' "$report_date"
    printf 'generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "---"
    printf '\n'
    printf '# Queue Report — %s\n' "$report_date"
    printf '\n'
    printf '## Summary\n'
    printf '\n'
    printf '| Status | Count |\n'
    printf '|--------|-------|\n'
    printf '| Completed | %s |\n' "$completed"
    printf '| Failed | %s |\n' "$failed"
    printf '| Dead-lettered | %s |\n' "$dead_lettered"
    printf '| Still pending | %s |\n' "$pending"
    printf '| Still running | %s |\n' "$running"
    printf '| **Total processed** | **%s** |\n' "$total"
    printf '\n'

    # Completed task details
    if (( completed > 0 )); then
      printf '## Completed Tasks\n'
      printf '\n'
      local f
      for f in "$QUEUE_COMPLETED_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        local bname
        bname=$(basename "$f")
        # Extract duration from comment if present
        local dur
        dur=$(grep -o 'duration_seconds: [0-9]*' "$f" 2>/dev/null | head -1 | cut -d' ' -f2)
        if [[ -n "$dur" ]]; then
          printf '- **%s** — %ss\n' "$bname" "$dur"
        else
          printf '- **%s**\n' "$bname"
        fi
      done
      printf '\n'
    fi

    # Failed task details
    if (( failed > 0 )); then
      printf '## Failed Tasks\n'
      printf '\n'
      local f
      for f in "$QUEUE_FAILED_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        local bname
        bname=$(basename "$f")
        local exit_code
        exit_code=$(grep -o 'failure_exit_code: [0-9]*' "$f" 2>/dev/null | head -1 | cut -d' ' -f2)
        if [[ -n "$exit_code" ]]; then
          printf '- **%s** — exit code %s\n' "$bname" "$exit_code"
        else
          printf '- **%s**\n' "$bname"
        fi
      done
      printf '\n'
    fi

    # Dead-letter details
    if (( dead_lettered > 0 )); then
      printf '## Dead-Lettered (Poison Tasks)\n'
      printf '\n'
      local f
      for f in "$QUEUE_DEAD_LETTER_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        local bname
        bname=$(basename "$f")
        local reason_file="${f}.reason"
        if [[ -f "$reason_file" ]]; then
          local reason
          reason=$(head -c 200 "$reason_file")
          printf '- **%s** — %s\n' "$bname" "$reason"
        else
          printf '- **%s**\n' "$bname"
        fi
      done
      printf '\n'
    fi

    # Blockers
    if (( failed > 0 || dead_lettered > 0 )); then
      printf '## Blockers\n'
      printf '\n'
      if (( dead_lettered > 0 )); then
        printf '- %s task(s) hit poison threshold — manual review needed\n' "$dead_lettered"
      fi
      if (( failed > 0 )); then
        printf '- %s task(s) failed — check failed/ directory for details\n' "$failed"
      fi
      printf '\n'
    fi

  } > "$report_file"

  cat "$report_file"
  _queue_log "Report written: ${report_file}"
  return 0
}

# ---------------------------------------------------------------------------
# Exports — all functions available when sourced
# ---------------------------------------------------------------------------
export -f enqueue_task
export -f dequeue_next
export -f queue_status
export -f run_queue
export -f queue_report
export -f _queue_log
export -f _queue_ensure_dirs
export -f _queue_count
export -f _queue_validate_priority
