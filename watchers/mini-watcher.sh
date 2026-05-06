#!/bin/bash
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

INBOX="$HOME/.myndaix/bridge/inbox/mini"
OUTBOX="$HOME/.myndaix/bridge/inbox/lobster"
PROCESSED="$HOME/.myndaix/bridge/processed"
LOCKDIR="$HOME/.myndaix/bridge/locks/mini-watcher.lock"
LOG="$HOME/.myndaix/bridge/watchers/mini-watcher.log"
RUNNER="$HOME/.myndaix/bridge/watchers/mini-runner.sh"
STATE_FILE="$HOME/.myndaix/bridge/state/mini-daily-runs.json"
WORKTREE_ROOT="/tmp/mini-worktrees"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

MAX_TASK_BYTES=51200
DEFAULT_TIMEOUT=900
MAX_TIMEOUT=2400
STALE_LOCK_SECS=900

mkdir -p "$INBOX" "$OUTBOX" "$PROCESSED" "$WORKTREE_ROOT" "$HOME/.myndaix/bridge/locks" "$HOME/.myndaix/bridge/state" "$HOME/.myndaix/bridge/watchers"

# ── Source shared + phase libraries ──
AGENT_NAME="mini"
REJECT_STYLE="builder"
WRITE_ACK="true"
LIB_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/guardrails.sh"
source "$LIB_DIR/context.sh"
source "$LIB_DIR/chaining.sh"
source "$LIB_DIR/self-healing.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/parallel.sh"
source "$LIB_DIR/queue.sh"
source "$LIB_DIR/knowledge.sh"

verify_hooks_loaded() {
  if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    log "ERROR: missing $CLAUDE_SETTINGS"
    return 1
  fi
  if ! grep -q "branch-guard.sh" "$CLAUDE_SETTINGS" 2>/dev/null; then
    log "ERROR: safety hooks not configured in settings.json (branch-guard missing)"
    return 1
  fi
  if ! grep -q "destructive-blocker.sh" "$CLAUDE_SETTINGS" 2>/dev/null; then
    log "ERROR: safety hooks not configured in settings.json (destructive-blocker missing)"
    return 1
  fi
  if ! grep -q "syntax-check.sh" "$CLAUDE_SETTINGS" 2>/dev/null; then
    log "ERROR: safety hooks not configured in settings.json (syntax-check missing)"
    return 1
  fi
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
  "max_failures": 5,
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
      "max_failures": int(data.get("max_failures", 5) or 5),
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
fails=int(d.get("failures",0)); max_fails=int(d.get("max_failures",5))
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

engine_health_check() {
  if curl -sf -o /dev/null --max-time 5 http://localhost:3457/health 2>/dev/null; then
    return 0
  fi
  if nc -z localhost 3457 2>/dev/null; then
    return 0
  fi
  return 1
}

if ! verify_hooks_loaded; then
  exit 1
fi


# ══════════════════════════════════════════════════════════
# AUTOIMMUNE SYSTEM — standard guards for all MyndAIX agents
# ══════════════════════════════════════════════════════════

# ── Daily task cap ──
MAX_DAILY_TASKS=50
if [[ -f "$STATE_FILE" ]]; then
  daily_runs=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('runs',0))" "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$daily_runs" -ge "$MAX_DAILY_TASKS" ] 2>/dev/null; then
    log "Daily task cap reached ($daily_runs/$MAX_DAILY_TASKS) — mini is resting"
    exit 0
  fi
fi

# ── Stale process reaper ──
while IFS= read -r reap_line; do
  cpid=$(echo "$reap_line" | awk '{print $2}')
  elapsed=$(ps -o etime= -p "$cpid" 2>/dev/null | tr -d ' ')
  if [[ -n "$elapsed" ]]; then
    if echo "$elapsed" | grep -qE '^[0-9]+-|^[0-9]+:[0-9]+:[0-9]+'; then
      log "REAPER: Killing stale mini process PID=$cpid (elapsed=$elapsed)"
      kill -9 "$cpid" 2>/dev/null || true
    fi
  fi
done < <(ps aux | grep "claude.*dangerously-skip" | grep -v grep 2>/dev/null || true)

# Circuit breaker handled by check_pain (Upgrade 2)

# ── Concurrency limit ──
MAX_CONCURRENT=3
current_procs=$(ps aux | grep "claude.*dangerously-skip" | grep -v grep 2>/dev/null | wc -l | tr -d ' ')
if [ "$current_procs" -ge "$MAX_CONCURRENT" ] 2>/dev/null; then
  log "Concurrency limit: $current_procs processes (max $MAX_CONCURRENT) — skipping"
  exit 0
fi

if ! acquire_lock; then
  log "Lock held by active run, skipping"
  exit 0
fi

# Global trap: release lock on exit (worktree cleanup is per-iteration)
trap 'rm -rf "$LOCKDIR"' EXIT

# ── Drain loop: process ALL queued tasks before exiting ──
DRAIN_COUNT=0
while true; do

# ── Pause check (Upgrade 2) — runs FIRST, before any claim ──
# Must precede claim_task to avoid claim/skip loops that inflate telemetry
# and feed the re-scan/exec cycle. Exit (not continue) so fswatch can re-fire.
if [ -f "$HOME/.myndaix/bridge/state/${AGENT_NAME}-paused" ]; then
  if [ -n "${TASK_ID:-}" ]; then
    complete_task "$TASK_ID" "skipped" "" "" "agent_paused" 2>/dev/null || true
  fi
  log "[PAUSED] ${AGENT_NAME} is paused by circuit breaker — exiting drain loop"
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
  if (( DRAIN_COUNT == 0 )); then
    log "No tasks in inbox"
  else
    log "Inbox drained — processed $DRAIN_COUNT task(s)"
  fi
  break
fi

TASK_NAME=$(basename "$TASK_FILE")
log "Processing task: $TASK_NAME (drain iteration $((DRAIN_COUNT+1)))"
log_task "${TASK_NAME%.md}" "mini" "task" "claimed" "unknown"

# ── Schema validation (task contract) ──
# (Pause check now runs at top of drain loop — see above)

# ── Schema validation (Upgrade 2 — replaces validate-task.sh) ──
if ! validate_task "$TASK_FILE"; then
  log "REJECTED: $TASK_NAME — failed schema validation (moved to rejected/)"
  continue
fi
log "Schema validation passed for $TASK_NAME"


TASK_SIZE=$(wc -c < "$TASK_FILE" | tr -d ' ')
if (( TASK_SIZE > MAX_TASK_BYTES )); then
  reject_task "$TASK_NAME" "task exceeds max size (${TASK_SIZE} bytes > ${MAX_TASK_BYTES} bytes)"
  archive_task "$TASK_FILE"
  continue
fi

frontmatter_json=""
if ! frontmatter_json=$(parse_frontmatter_json "$TASK_FILE" 2>/dev/null); then
  log "Skipping: $TASK_NAME (no valid frontmatter) — leaving in inbox"
  break  # Can't process this file; break to avoid infinite loop on same file
fi

task_type=$(json_get "$frontmatter_json" "type")
if [[ "$task_type" != "task" ]]; then
  log "Skipping: $TASK_NAME (type=${task_type:-unset}) — leaving in inbox"
  break  # Non-task file blocks drain; break to avoid infinite loop
fi

tier=$(json_get "$frontmatter_json" "tier")
task_id=$(json_get "$frontmatter_json" "task_id")
from=$(json_get "$frontmatter_json" "from")

# ── Dedupe check (guardrails.sh) ──
if [[ -n "$task_id" ]]; then
  if ! check_dedupe "$task_id"; then
    log "DEDUPE: $TASK_NAME (task_id=$task_id) already processed within 24h — skipping"
    archive_task "$TASK_FILE"
    continue
  fi
fi

if [[ -z "$tier" || "$tier" != "auto" ]]; then
  reject_task "$TASK_NAME" "tier is not 'auto' (got: '${tier:-missing}')"
  archive_task "$TASK_FILE"
  continue
fi
# Authorized senders: lobster (orchestrator) + peer agents via agent-dispatch
AUTHORIZED_SENDERS="lobster mini antman mack jefe oracle recon harley notion-poller cli"
if [[ -z "$from" ]] || ! echo "$AUTHORIZED_SENDERS" | grep -Fqw "$from"; then
  reject_task "$TASK_NAME" "sender '$from' is not authorized for mini (allowed: $AUTHORIZED_SENDERS)"
  archive_task "$TASK_FILE"
  continue
fi

ensure_budget_file
budget_reason=$(budget_block_reason || true)
if [[ -n "$budget_reason" ]]; then
  log "$budget_reason — task stays in inbox for next budget window"
  break  # Budget exhausted, stop processing entirely
fi

repo=$(json_get "$frontmatter_json" "repo")
if [[ -z "$repo" ]]; then
  repo=$(json_get "$frontmatter_json" "project")
fi
# Only use scope as repo if it looks like a path (not a JSON object)
scope_val=$(json_get "$frontmatter_json" "scope")
if [[ -z "$repo" && -n "$scope_val" && "$scope_val" == /* ]]; then
  repo="$scope_val"
fi
if [[ -z "$repo" || "$repo" == "none" || "$repo" == "null" ]]; then
  repo="$HOME/.openclaw/workspace"
fi

if [[ ! -d "$repo" ]]; then
  reject_task "$TASK_NAME" "repo path not found: $repo"
  archive_task "$TASK_FILE"
  continue
fi
if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  reject_task "$TASK_NAME" "repo path is not a git worktree: $repo"
  archive_task "$TASK_FILE"
  continue
fi

timeout_secs=$(json_get "$frontmatter_json" "timeout")
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

# Branch-aware build: if task frontmatter specifies a branch, use it directly
# so downstream reviewers see work on the intended feature branch (not mini/*).
# Falls back to auto-generated mini/<slug> branch when no branch: is set.
task_branch=$(json_get "$frontmatter_json" "branch")

if [[ -n "$task_branch" ]]; then
  BRANCH_NAME="$task_branch"
  # Try to check out the existing branch (local or remote-tracking).
  # If that fails, create the branch fresh (new feature branch from HEAD).
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
        write_result "$TASK_NAME" "$task_branch" "$WORKTREE_DIR" "mini-watcher" "FAILED" "$body"
        rm -f "$body"
        budget_increment failures
        archive_task "$TASK_FILE"
        continue
      fi
    fi
  fi
  log "Using task-specified branch: $BRANCH_NAME"
else
  BRANCH_NAME="mini/${TASK_SLUG}"
  if ! git -C "$repo" worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" >/dev/null 2>&1; then
    body=$(mktemp)
    {
      echo "Failed to create git worktree."
      echo "Repo: $repo"
      echo "Branch: $BRANCH_NAME"
    } > "$body"
    write_result "$TASK_NAME" "$BRANCH_NAME" "$WORKTREE_DIR" "mini-watcher" "FAILED" "$body"
    rm -f "$body"
    budget_increment failures
    archive_task "$TASK_FILE"
    continue
  fi
fi

budget_increment runs

# ── Per-task retry budget check (guardrails.sh) ──
if [[ -n "$task_id" ]]; then
  TASK_MAX_RETRIES=2
  if ! check_retry_budget "$task_id" "$TASK_MAX_RETRIES"; then
    log "RETRY_BUDGET: $TASK_NAME (task_id=$task_id) exhausted $TASK_MAX_RETRIES retries — dead-lettering"
    dead_letter "$TASK_FILE" "Retry budget exhausted ($TASK_MAX_RETRIES)"
    escalate_to_lobster "$task_id" "$FAILURE_UNKNOWN" "Retry budget exhausted after $TASK_MAX_RETRIES attempts" "$TASK_FILE"
    git -C "$repo" worktree remove "$WORKTREE_DIR" --force >/dev/null 2>&1 || true
    continue
  fi
fi

# ── Preflight validation (preflight.sh) ──
if ! preflight_check "$TASK_FILE"; then
  preflight_warnings=$(preflight_get_warnings)
  log "PREFLIGHT: $TASK_NAME has warnings: $preflight_warnings"
  # Warnings are non-blocking — log but continue (matches mack pattern)
fi

# ── Claim task lock (parallel.sh) — prevent duplicate execution across agents ──
if [[ -n "$task_id" ]]; then
  if ! claim_task_parallel "$task_id" "mini"; then
    log "PARALLEL: $TASK_NAME (task_id=$task_id) already claimed by another agent — leaving for retry"
    git -C "$repo" worktree remove "$WORKTREE_DIR" --force >/dev/null 2>&1 || true
    break  # Task still in inbox, can't skip past it
  fi
fi

# ── Memory injection (Upgrade 3) — passed to runner via env vars ──
# Runner can't source common.sh (top-level env guards), so query here and export.
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
fallback_used=0

if engine_health_check; then
  if "$RUNNER" claude "$WORKTREE_DIR" "$TASK_FILE" "$timeout_secs" >"$TMP_OUT" 2>"$TMP_ERR"; then
    ENGINE_USED="claude-code:claude-opus-4-6"
    RUN_RC=0
  else
    RUN_RC=$?
  fi
else
  RUN_RC=1
fi

if (( RUN_RC != 0 )); then
  fallback_used=1
  if command -v codex >/dev/null 2>&1; then
    if "$RUNNER" codex "$WORKTREE_DIR" "$TASK_FILE" "$timeout_secs" >"$TMP_OUT" 2>"$TMP_ERR"; then
      ENGINE_USED="codex:gpt-5.3-codex"
      RUN_RC=0
    else
      RUN_RC=$?
    fi
  fi
fi

if [[ "$RUN_RC" -eq 0 ]]; then
  if ! git -C "$WORKTREE_DIR" diff --quiet || ! git -C "$WORKTREE_DIR" diff --cached --quiet; then
    git -C "$WORKTREE_DIR" add -A >/dev/null 2>&1 || true
    git -C "$WORKTREE_DIR" commit -m "mini: ${TASK_NAME}" >/dev/null 2>&1 || true
    # CRITICAL: Push before cleanup destroys the worktree
    git -C "$WORKTREE_DIR" push origin "$BRANCH_NAME" >/dev/null 2>&1 || log "WARNING: git push failed for $BRANCH_NAME"
  fi
fi

# ── Release task lock (parallel.sh) ──
if [[ -n "$task_id" ]]; then
  release_task_parallel "$task_id" "mini" || true
fi

VALIDATION="PASS"
if [[ "$RUN_RC" -eq 124 ]]; then
  VALIDATION="TIMEOUT"
elif [[ "$RUN_RC" -eq 43 ]]; then
  VALIDATION="CONTEXT_OVERFLOW"
elif [[ "$RUN_RC" -ne 0 ]]; then
  VALIDATION="FAILED"
fi

# ── Self-healing flow (self-healing.sh) ──
if [[ "$VALIDATION" != "PASS" && -n "$task_id" ]]; then
  error_output=""
  [[ -s "$TMP_ERR" ]] && error_output=$(tail -n 40 "$TMP_ERR")
  failure_code=$(classify_failure "$RUN_RC" "$error_output")
  healing_action=$(handle_failure "$task_id" "$failure_code" "$error_output" "$TASK_FILE" 2)

  case "$healing_action" in
    RETRY)
      log "SELF-HEALING: $TASK_NAME — will retry (action=$healing_action)"
      # Inject retry context into task for next attempt
      retry_ctx=$(get_retry_context "$task_id")
      if [[ -n "$retry_ctx" ]]; then
        log "SELF-HEALING: retry context saved for $task_id"
      fi
      ;;
    BUDGET_EXHAUSTED|NO_RETRY)
      log "SELF-HEALING: $TASK_NAME — escalated to lobster (action=$healing_action)"
      ;;
    SKIP_ACKED)
      log "SELF-HEALING: $TASK_NAME — already handled (action=$healing_action)"
      ;;
  esac
fi

# ── Build result envelope (context.sh) ──
files_changed=""
if [[ "$RUN_RC" -eq 0 ]]; then
  files_changed=$(git -C "$WORKTREE_DIR" diff --name-only HEAD~1 2>/dev/null | head -20 | tr '\n' ',' || true)
fi
dispatch_to=$(json_get "$frontmatter_json" "dispatch_to")
chain_id=$(json_get "$frontmatter_json" "chain_id")
chain_depth=$(json_get "$frontmatter_json" "chain_depth")
[[ -z "$chain_depth" ]] && chain_depth=0

BODY=$(mktemp)
{
  build_result_envelope "$VALIDATION" \
    "Task: $TASK_NAME (engine: $ENGINE_USED, fallback: $fallback_used)" \
    "$files_changed" \
    "" \
    "$dispatch_to" \
    "$chain_id" \
    "$chain_depth"
  echo
  echo "## Details"
  echo "Repo: $repo"
  echo "Branch: $BRANCH_NAME"
  echo "Worktree: $WORKTREE_DIR"
  echo "Timeout: ${timeout_secs}s"
  echo "Fallback used: $fallback_used"
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
  # ── Enqueue failed task for retry (queue.sh) ──
  if [[ -n "$task_id" ]]; then
    priority=$(json_get "$frontmatter_json" "priority")
    [[ -z "$priority" ]] && priority="P2"
    enqueue_task "$task_id" "$priority" "mini" "Retry: $TASK_NAME" "$TASK_FILE" || \
      log "WARNING: failed to enqueue $task_id for retry"
  fi
fi

write_result "$TASK_NAME" "$BRANCH_NAME" "$WORKTREE_DIR" "$ENGINE_USED" "$VALIDATION" "$BODY"

# ── Mandatory Oracle review (async, non-blocking) ────────────────────────────
ORACLE_DISPATCH="$HOME/.myndaix/bridge/scripts/dispatch-oracle-review.sh"
if [[ -x "$ORACLE_DISPATCH" ]] && [[ "$VALIDATION" == "PASS" ]]; then
  DURABLE_BODY="$HOME/.myndaix/bridge/state/mini-oracle-body-$(date +%s).md"
  cp "$BODY" "$DURABLE_BODY"
  "$ORACLE_DISPATCH" mini "$TASK_NAME" "$repo" "$BRANCH_NAME" "$WORKTREE_DIR" "$DURABLE_BODY" >> "$LOG" 2>&1 || log "ERROR: Oracle dispatch failed for $TASK_NAME (rc=$?)"
  log "Oracle review dispatched for $TASK_NAME"
fi

# Event-driven: ping Lobster via Discord #command-center
if command -v openclaw >/dev/null 2>&1; then
  status_icon="✅"
  [[ "$VALIDATION" == "FAILED" ]] && status_icon="❌"
  [[ "$VALIDATION" == "TIMEOUT" ]] && status_icon="⏰"
  [[ "$VALIDATION" == "REJECTED" ]] && status_icon="🚫"
  openclaw message send --channel discord -t "${DISCORD_COMMAND_CHANNEL:-}" \
    -m "${status_icon} **Mini finished:** ${TASK_NAME%.md} — ${VALIDATION} (engine: ${ENGINE_USED})" \
    --silent 2>/dev/null &
  log "Pinged Lobster via Discord #command-center"
fi

# ── Auto Smoke QA (async, non-blocking) ──
SMOKE_DISPATCH="$HOME/.myndaix/bridge/scripts/dispatch-smoke-qa.sh"
if [[ -x "$SMOKE_DISPATCH" ]] && [[ "$VALIDATION" == "PASS" ]]; then
  DURABLE_SMOKE_BODY="$HOME/.myndaix/bridge/state/mini-smoke-body-$(date +%s).md"
  cp "$BODY" "$DURABLE_SMOKE_BODY"
  "$SMOKE_DISPATCH" mini "$TASK_NAME" "$repo" "$BRANCH_NAME" "$WORKTREE_DIR" "$DURABLE_SMOKE_BODY" >> "$LOG" 2>&1 || log "ERROR: Smoke QA dispatch failed for $TASK_NAME (rc=$?)"
  log "Smoke QA dispatched for $TASK_NAME"
fi

# ── Chaining dispatch (chaining.sh) ──
if [[ "$VALIDATION" == "PASS" ]]; then
  if dispatch_next "$BODY"; then
    log "Chain dispatch processed for $TASK_NAME"
  else
    log "WARNING: chain dispatch failed for $TASK_NAME (rc=$?)"
  fi
fi

# ── Context checkpoint (Phase 1) ──
CHECKPOINT_SCRIPT="$HOME/.myndaix/bridge/scripts/write-checkpoint.sh"
if [[ -x "$CHECKPOINT_SCRIPT" ]]; then
  "$CHECKPOINT_SCRIPT" \
    --agent mini \
    --topic "${subject:-$TASK_NAME}" \
    --completed "${subject:-$TASK_NAME}" \
    --decisions "engine=$ENGINE_USED validation=$VALIDATION" \
    --next "awaiting next dispatch" \
    --task-id "${task_id:-}" \
    >> "$LOG" 2>&1 || true
fi

# ── Completion signal (Phase 2 prep) ──
COMPLETION_SCRIPT="$HOME/.myndaix/bridge/scripts/write-completion.sh"
if [[ -x "$COMPLETION_SCRIPT" ]]; then
  "$COMPLETION_SCRIPT" \
    --agent mini \
    --task-id "${task_id:-$TASK_NAME}" \
    --task-name "${subject:-$TASK_NAME}" \
    --result "$VALIDATION" \
    --repo "$repo" \
    --branch "$BRANCH_NAME" \
    >> "$LOG" 2>&1 || true
fi

write_heartbeat "$TASK_NAME" "$VALIDATION"
# extract_knowledge must run BEFORE $BODY is deleted — it reads the file.
extract_knowledge "mini" "$TASK_FILE" "$BODY" "$VALIDATION"
rm -f "$BODY" "$TMP_OUT" "$TMP_ERR"
archive_task "$TASK_FILE"
log_task "${task_id:-${TASK_NAME%.md}}" "mini" "task" "$(echo "$VALIDATION" | tr '[:upper:]' '[:lower:]')" "$ENGINE_USED"
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

# ── Per-iteration worktree cleanup ──
git -C "$repo" worktree remove "$WORKTREE_DIR" --force >/dev/null 2>&1 || true

DRAIN_COUNT=$((DRAIN_COUNT + 1))
sleep 2  # Brief pause between tasks to avoid runaway loops

done  # ── End drain loop ──

# ── Re-scan: catch files that arrived during processing ──
# WatchPaths only triggers once per directory change. If files landed while
# we were busy, they'd sit until the next external event. Re-check up to
# 3 times with a short delay to catch stragglers.
RESCAN=0
MAX_RESCAN=3
while (( RESCAN < MAX_RESCAN )); do
  sleep 5
  PENDING=$(find "$INBOX" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  if (( PENDING == 0 )); then
    break
  fi
  RESCAN=$((RESCAN + 1))
  log "Re-scan ${RESCAN}/${MAX_RESCAN}: ${PENDING} new task(s) found — releasing lock and re-exec"
  rm -rf "$LOCKDIR"
  trap - EXIT  # Disarm old trap so it doesn't double-remove
  exec /bin/bash "$0"
done
