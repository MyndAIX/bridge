#!/usr/bin/env bash
# self-healing.sh — Self-healing library for bridge watchers
# Provides: handle_failure, retry_task, classify_failure, escalate_to_lobster
#
# Usage: source this file from watchers
# Requires: guardrails.sh (sourced first or auto-sourced)
#
# No side effects on load — all state changes happen inside function calls.

# ---------------------------------------------------------------------------
# Auto-source guardrails.sh if not already loaded
# ---------------------------------------------------------------------------
_SELF_HEALING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f dead_letter >/dev/null 2>&1; then
  source "$_SELF_HEALING_LIB_DIR/guardrails.sh"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
SELF_HEALING_STATE_DIR="${BRIDGE_DIR}/state/self-healing"
SELF_HEALING_ACK_DIR="${SELF_HEALING_STATE_DIR}/ack"
DEFAULT_RETRY_BUDGET=2

# ---------------------------------------------------------------------------
# Typed Failure Codes
# ---------------------------------------------------------------------------
FAILURE_TIMEOUT=1
FAILURE_ENGINE_ERROR=2
FAILURE_VALIDATION=3
FAILURE_PERMISSION=4
FAILURE_UNKNOWN=99

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _sh_log <message>
_sh_log() {
  if declare -f log >/dev/null 2>&1; then
    log "[self-healing] $1"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [self-healing] $1" >&2
  fi
}

# _sanitize_task_id <task_id>
# Wrapper around shared _sanitize_id from guardrails.sh
_sanitize_task_id() {
  _sanitize_id "$1"
}

# _sanitize_context <error_context>
# Strips control chars and caps length for safe embedding in prompts/files.
_sanitize_context() {
  local ctx="$1"
  # Strip control chars except newline/tab
  ctx=$(printf '%s' "$ctx" | tr -d '\000-\010\013\014\016-\037')
  # Cap at 2000 chars
  printf '%s' "${ctx:0:2000}"
}

# _failure_name <code>
# Returns human-readable name for a failure code.
_failure_name() {
  case "$1" in
    "$FAILURE_TIMEOUT")      echo "TIMEOUT" ;;
    "$FAILURE_ENGINE_ERROR") echo "ENGINE_ERROR" ;;
    "$FAILURE_VALIDATION")   echo "VALIDATION_FAILED" ;;
    "$FAILURE_PERMISSION")   echo "PERMISSION_DENIED" ;;
    *)                       echo "UNKNOWN" ;;
  esac
}

# _is_retryable <failure_code>
# Returns 0 if the failure type should be retried, 1 if not.
_is_retryable() {
  local code="$1"
  case "$code" in
    "$FAILURE_TIMEOUT")      return 0 ;;  # retry with longer timeout
    "$FAILURE_ENGINE_ERROR") return 0 ;;  # retry with fallback engine
    "$FAILURE_VALIDATION")   return 1 ;;  # bad input, don't retry
    "$FAILURE_PERMISSION")   return 1 ;;  # escalate immediately
    "$FAILURE_UNKNOWN")      return 0 ;;  # retry once, then escalate
    *)                       return 1 ;;
  esac
}

# _max_retries_for <failure_code> <default_budget>
# Returns effective retry budget based on failure type.
_max_retries_for() {
  local code="$1"
  local budget="$2"
  case "$code" in
    "$FAILURE_UNKNOWN") echo 1 ;;          # UNKNOWN: retry once max
    *)                  echo "$budget" ;;   # all others use configured budget
  esac
}

# ---------------------------------------------------------------------------
# Idempotency — ack log
# ---------------------------------------------------------------------------

# check_ack <task_id> <attempt>
# Returns 0 if this task+attempt has NOT been processed, 1 if already acked.
check_ack() {
  local task_id
  task_id=$(_sanitize_task_id "$1")
  local attempt="$2"
  local ack_file="${SELF_HEALING_ACK_DIR}/${task_id}_attempt${attempt}.ack"

  if [[ -f "$ack_file" ]]; then
    return 1  # already processed
  fi
  return 0
}

# _record_ack <task_id> <attempt>
# Marks this task+attempt as processed.
_record_ack() {
  local task_id
  task_id=$(_sanitize_task_id "$1")
  local attempt="$2"
  mkdir -p "$SELF_HEALING_ACK_DIR"
  local ack_file="${SELF_HEALING_ACK_DIR}/${task_id}_attempt${attempt}.ack"
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$ack_file"
}

# ---------------------------------------------------------------------------
# Escalation
# ---------------------------------------------------------------------------

# escalate_to_lobster <task_id> <failure_code> <error_context> [task_file]
# Writes an alert to lobster's inbox with failure details.
escalate_to_lobster() {
  local task_id="$1"
  local failure_code="$2"
  local error_context="$3"
  local task_file="${4:-}"

  local lobster_inbox="${BRIDGE_DIR}/inbox/lobster"
  mkdir -p "$lobster_inbox"

  local safe_task_id ts failure_name alert_file
  safe_task_id=$(_sanitize_task_id "$task_id")
  ts=$(date -u '+%Y%m%d%H%M%S')
  failure_name=$(_failure_name "$failure_code")
  alert_file="${lobster_inbox}/${ts}-alert-${safe_task_id}.md"

  # Sanitize error_context for safe file output
  local safe_error_context
  safe_error_context=$(_sanitize_context "$error_context")

  {
    printf '%s\n' "---"
    printf '%s\n' "from: mini"
    printf '%s\n' "to: lobster"
    printf '%s\n' "type: alert"
    printf 'subject: "Task failed after retries: %s"\n' "$safe_task_id"
    printf 'failure_code: %s\n' "$failure_name"
    printf 'task_id: %s\n' "$safe_task_id"
    printf 'created: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "tier: auto"
    printf '%s\n' "---"
    printf '\n'
    printf '%s\n' "## Failure Report"
    printf '\n'
    printf '**Task:** %s\n' "$safe_task_id"
    printf '**Failure:** %s (code %s)\n' "$failure_name" "$failure_code"
    printf '%s\n' "**Retries exhausted:** yes"
    printf '\n'
    printf '%s\n' "## Error Context"
    printf '\n'
    printf '%s\n' "$safe_error_context"
    printf '\n'
    if [[ -n "$task_file" && -f "$task_file" ]]; then
      printf '%s\n' "## Original Task"
      printf '\n'
      printf 'File: %s\n' "$task_file"
    fi
  } > "$alert_file"

  _sh_log "Escalated task ${task_id} (${failure_name}) to lobster: ${alert_file}"
  return 0
}

# ---------------------------------------------------------------------------
# Core: retry_task
# ---------------------------------------------------------------------------

# retry_task <task_id> <failure_code> <error_context> <task_file> [retry_budget]
#
# Orchestrates retry logic:
#   1. Check idempotency (skip if task+attempt already acked)
#   2. Check if failure type is retryable
#   3. Check retry budget via guardrails.sh
#   4. If retries remain: record ack, return 0 (caller should retry)
#   5. If exhausted: dead-letter + escalate, return 1
#
# Outputs (on stdout):
#   RETRY          — caller should retry the task
#   SKIP_ACKED     — already processed this attempt, skip
#   NO_RETRY       — failure type not retryable
#   BUDGET_EXHAUSTED — retries used up, escalated
#
# Return codes:
#   0 = retry (caller should execute the task again)
#   1 = do not retry (escalated or non-retryable)
#   2 = skip (already acked)
retry_task() {
  local task_id
  task_id=$(_sanitize_task_id "$1")
  local failure_code="$2"
  local error_context
  error_context=$(_sanitize_context "$3")
  local task_file="$4"
  local retry_budget="${5:-$DEFAULT_RETRY_BUDGET}"

  local failure_name
  failure_name=$(_failure_name "$failure_code")

  # Effective budget may be lower for certain failure types
  local effective_budget
  effective_budget=$(_max_retries_for "$failure_code" "$retry_budget")

  # Get current attempt number (peek at state without incrementing)
  local retry_dir="${GUARDRAIL_STATE_DIR}/retries"
  local count_file="${retry_dir}/${task_id}.count"
  local current_attempt=0
  if [[ -f "$count_file" ]]; then
    current_attempt=$(cat "$count_file")
    if ! [[ "$current_attempt" =~ ^[0-9]+$ ]]; then
      current_attempt=0
    fi
  fi
  local next_attempt=$(( current_attempt + 1 ))

  _sh_log "Task ${task_id}: ${failure_name} (code ${failure_code}), attempt ${next_attempt}/${effective_budget}"

  # 1. Idempotency check
  if ! check_ack "$task_id" "$next_attempt"; then
    _sh_log "Task ${task_id} attempt ${next_attempt} already acked — skipping"
    echo "SKIP_ACKED"
    return 2
  fi

  # 2. Retryable check
  if ! _is_retryable "$failure_code"; then
    _sh_log "Task ${task_id}: ${failure_name} is not retryable — escalating"
    escalate_to_lobster "$task_id" "$failure_code" "$error_context" "$task_file"
    if [[ -n "$task_file" ]]; then
      dead_letter "$task_file" "Non-retryable failure: ${failure_name}"
    fi
    echo "NO_RETRY"
    return 1
  fi

  # 3. Budget check (this increments the counter)
  if ! check_retry_budget "$task_id" "$effective_budget"; then
    _sh_log "Task ${task_id}: retry budget exhausted (${effective_budget}) — dead-lettering + escalating"
    escalate_to_lobster "$task_id" "$failure_code" "$error_context" "$task_file"
    if [[ -n "$task_file" ]]; then
      dead_letter "$task_file" "Retries exhausted (${effective_budget}): ${failure_name}"
    fi
    echo "BUDGET_EXHAUSTED"
    return 1
  fi

  # 4. OK to retry — record ack
  _record_ack "$task_id" "$next_attempt"
  _sh_log "Task ${task_id}: will retry (attempt ${next_attempt}/${effective_budget})"
  echo "RETRY"
  return 0
}

# ---------------------------------------------------------------------------
# Core: handle_failure
# ---------------------------------------------------------------------------

# handle_failure <task_id> <failure_code> <error_context> <task_file> [retry_budget]
#
# High-level failure handler for watchers. Wraps retry_task with
# error context injection for the retry prompt.
#
# Returns same codes as retry_task.
# Writes retry context to $SELF_HEALING_STATE_DIR/<task_id>.retry_context
# Caller reads it with: get_retry_context <task_id>
handle_failure() {
  local task_id
  task_id=$(_sanitize_task_id "$1")
  local failure_code="$2"
  local error_context
  error_context=$(_sanitize_context "$3")
  local task_file="$4"
  local retry_budget="${5:-$DEFAULT_RETRY_BUDGET}"

  local failure_name
  failure_name=$(_failure_name "$failure_code")

  # Build retry context that callers can inject into retry prompts
  mkdir -p "$SELF_HEALING_STATE_DIR"
  local ctx_file="${SELF_HEALING_STATE_DIR}/${task_id}.retry_context"
  local retry_ctx="Previous attempt failed with ${failure_name}. Error: ${error_context}"

  # Add failure-specific hints
  case "$failure_code" in
    "$FAILURE_TIMEOUT")
      retry_ctx="${retry_ctx}
Hint: The previous attempt timed out. Consider a simpler approach or break the task into smaller steps." ;;
    "$FAILURE_ENGINE_ERROR")
      retry_ctx="${retry_ctx}
Hint: The AI engine returned an error. A different model or rephrased prompt may help." ;;
  esac

  printf '%s' "$retry_ctx" > "$ctx_file"

  retry_task "$task_id" "$failure_code" "$error_context" "$task_file" "$retry_budget"
}

# get_retry_context <task_id>
# Reads the retry context written by handle_failure. Prints to stdout.
get_retry_context() {
  local task_id
  task_id=$(_sanitize_task_id "$1")
  local ctx_file="${SELF_HEALING_STATE_DIR}/${task_id}.retry_context"
  if [[ -f "$ctx_file" ]]; then
    cat "$ctx_file"
  fi
}

# ---------------------------------------------------------------------------
# Utility: classify_failure
# ---------------------------------------------------------------------------

# classify_failure <exit_code> <error_output>
# Heuristic classification of a failure into typed codes.
# Prints the failure code to stdout.
classify_failure() {
  local exit_code="$1"
  local error_output="$2"

  # Timeout signals
  if (( exit_code == 124 )); then
    echo "$FAILURE_TIMEOUT"
    return
  fi
  if echo "$error_output" | grep -qi -e "timeout" -e "timed out" -e "deadline exceeded"; then
    echo "$FAILURE_TIMEOUT"
    return
  fi

  # Permission errors
  if echo "$error_output" | grep -qi -e "permission denied" -e "forbidden" -e "unauthorized" -e "403"; then
    echo "$FAILURE_PERMISSION"
    return
  fi

  # Validation errors
  if echo "$error_output" | grep -qi -e "validation" -e "invalid input" -e "malformed" -e "parse error" -e "syntax error"; then
    echo "$FAILURE_VALIDATION"
    return
  fi

  # Engine/API errors
  if echo "$error_output" | grep -qi -e "api error" -e "rate limit" -e "overloaded" -e "500" -e "502" -e "503" -e "engine error" -e "model error"; then
    echo "$FAILURE_ENGINE_ERROR"
    return
  fi

  echo "$FAILURE_UNKNOWN"
}

# ---------------------------------------------------------------------------
# Exports — all functions available when sourced
# ---------------------------------------------------------------------------
export -f retry_task
export -f handle_failure
export -f classify_failure
export -f escalate_to_lobster
export -f check_ack
export -f _sh_log
export -f _failure_name
export -f _is_retryable
export -f _max_retries_for
export -f _record_ack
export -f get_retry_context
