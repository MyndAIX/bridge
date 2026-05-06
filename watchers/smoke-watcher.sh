#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

AGENT="smoke"
INBOX="$HOME/.myndaix/bridge/inbox/$AGENT"
OUTBOX="$HOME/.myndaix/bridge/inbox/lobster"
PROCESSED="$HOME/.myndaix/bridge/processed"
LOCKDIR="$HOME/.myndaix/bridge/locks/${AGENT}-watcher.lock"
LOG="$HOME/.myndaix/bridge/watchers/${AGENT}-watcher.log"
STATE_FILE="$HOME/.myndaix/bridge/state/${AGENT}-daily-runs.json"
WORKTREE_ROOT="/tmp/${AGENT}-worktrees"

MAX_TASK_BYTES=51200
DEFAULT_TIMEOUT=900
MAX_TIMEOUT=2400
STALE_LOCK_SECS=900

mkdir -p "$INBOX" "$OUTBOX" "$PROCESSED" "$WORKTREE_ROOT" \
  "$HOME/.myndaix/bridge/locks" "$HOME/.myndaix/bridge/state" \
  "$HOME/.myndaix/bridge/watchers"

# ── Source shared + phase libraries ──
AGENT_NAME="$AGENT"
REJECT_STYLE="builder"
LIB_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/guardrails.sh"
source "$LIB_DIR/context.sh"
source "$LIB_DIR/self-healing.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/chaining.sh"

ensure_budget_file() {
  python3 - "$STATE_FILE" <<'PY'
import json, os, sys, datetime
path = sys.argv[1]
today = datetime.date.today().isoformat()
default = {"date": today, "runs": 0, "max": 30, "failures": 0, "max_failures": 10}
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
    data = {"date": today, "runs": 0, "max": int(data.get("max", 30) or 30),
            "failures": 0, "max_failures": int(data.get("max_failures", 10) or 10)}
with open(path, "w") as f:
    json.dump(data, f)
PY
}

budget_block_reason() {
  python3 - "$STATE_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
runs = int(d.get("runs", 0)); max_runs = int(d.get("max", 30))
fails = int(d.get("failures", 0)); max_fails = int(d.get("max_failures", 10))
if runs >= max_runs:
    print(f"Daily run cap reached ({runs}/{max_runs})")
elif fails >= max_fails:
    print(f"Daily failure cap reached ({fails}/{max_fails})")
PY
}

budget_increment() {
  local key="$1"
  python3 - "$STATE_FILE" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d[key] = int(d.get(key, 0)) + 1
with open(path, "w") as f:
    json.dump(d, f)
PY
}

# --- Main ---

# ── Stale process reaper ──
# Kill claude processes older than 30 minutes (smoke tasks should never run that long)
STALE_MINUTES=30
while IFS= read -r line; do
  cpid=$(echo "$line" | awk {print })
  elapsed=$(ps -o etime= -p "$cpid" 2>/dev/null | tr -d  )
  if [[ -n "$elapsed" ]]; then
    # Parse elapsed time (formats: MM:SS, HH:MM:SS, D-HH:MM:SS)
    if [[ "$elapsed" =~ ^[0-9]+-|^[0-9]+:[0-9]+:[0-9]+ ]]; then
      # Hours or days old — definitely stale
      log "REAPER: Killing stale claude process PID=$cpid (elapsed=$elapsed)"
      kill -9 "$cpid" 2>/dev/null || true
    fi
  fi
done < <(ps aux | grep "claude.*dangerously-skip" | grep -v grep 2>/dev/null)

# ── Concurrency limit ──
MAX_CONCURRENT_CLAUDE=3
current_claude=$(ps aux | grep "claude.*dangerously-skip" | grep -v grep | wc -l | tr -d  )
if (( current_claude >= MAX_CONCURRENT_CLAUDE )); then
  log "Concurrency limit: $current_claude claude processes running (max $MAX_CONCURRENT_CLAUDE) — skipping"
  exit 0
fi

if ! acquire_lock; then
  log "Lock held by active run, skipping"
  exit 0
fi

# Global trap: release lock on exit
trap 'rm -rf "$LOCKDIR"' EXIT

# ── Drain loop: process ALL queued tasks before exiting ──
DRAIN_COUNT=0
while true; do

TASK_FILE=$(pick_oldest_task)
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

# ── Schema validation (task contract) ──
if [ -x "$HOME/.myndaix/bridge/scripts/validate-task.sh" ]; then
  if ! "$HOME/.myndaix/bridge/scripts/validate-task.sh" "$TASK_FILE" "smoke" >> "$LOG" 2>&1; then
    log "REJECTED: $TASK_NAME — failed task contract schema validation"
    reject_task "$TASK_NAME" "failed task contract schema validation — see TASK_SCHEMA.md for required fields"
    archive_task "$TASK_FILE"
    continue
  fi
  log "Schema validation passed for $TASK_NAME"
fi

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
if [[ "$task_type" != "qa" && "$task_type" != "task" ]]; then
  log "Skipping: $TASK_NAME (type=${task_type:-unset}, expected qa or task) — leaving in inbox"
  break  # Non-matching type blocks drain; break to avoid infinite loop
fi

tier=$(json_get "$frontmatter_json" "tier")
task_id=$(json_get "$frontmatter_json" "task_id")
from=$(json_get "$frontmatter_json" "from")
subject=$(json_get "$frontmatter_json" "subject")
chain_id=$(json_get "$frontmatter_json" "chain_id")
chain_depth=$(json_get "$frontmatter_json" "chain_depth")

# ── Dedupe guard ──
if [[ -n "$task_id" ]] && ! check_dedupe "$task_id"; then
  log "DEDUPE: $TASK_NAME (task_id=$task_id) already processed — skipping"
  archive_task "$TASK_FILE"
  continue
fi

if [[ -z "$tier" || "$tier" != "auto" ]]; then
  reject_task "$TASK_NAME" "tier is not 'auto' (got: '${tier:-missing}')"
  archive_task "$TASK_FILE"
  continue
fi

# Authorized senders: lobster (orchestrator) + mini/antman/mack (peer dispatch)
AUTHORIZED_SENDERS="lobster mini antman mack jefe cli"
if [[ -z "$from" ]] || ! echo "$AUTHORIZED_SENDERS" | grep -qw "$from"; then
  reject_task "$TASK_NAME" "sender '$from' is not authorized for smoke (allowed: $AUTHORIZED_SENDERS)"
  archive_task "$TASK_FILE"
  continue
fi

# ── Chain depth guard ──
if [[ -n "$chain_id" ]]; then
  if ! check_chain_depth "$chain_id" "${MAX_CHAIN_DEPTH:-5}"; then
    log "Chain depth exceeded for chain_id=$chain_id — rejecting"
    reject_task "$TASK_NAME" "chain depth exceeded (max ${MAX_CHAIN_DEPTH:-5})"
    archive_task "$TASK_FILE"
    continue
  fi
fi

# ── Retry budget check ──
ensure_budget_file
budget_reason=$(budget_block_reason || true)
if [[ -n "$budget_reason" ]]; then
  log "$budget_reason — task stays in inbox for next budget window"
  break  # Budget exhausted, stop processing entirely
fi

repo=$(json_get "$frontmatter_json" "repo")
[[ -z "$repo" ]] && repo=$(json_get "$frontmatter_json" "project")
[[ -z "$repo" ]] && repo="$HOME/.myndaix/bridge"

if [[ ! -d "$repo" ]]; then
  reject_task "$TASK_NAME" "repo path not found: $repo"
  archive_task "$TASK_FILE"
  continue
fi
if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  reject_task "$TASK_NAME" "repo path is not a git repo: $repo"
  archive_task "$TASK_FILE"
  continue
fi

timeout_secs=$(json_get "$frontmatter_json" "timeout")
if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]]; then
  timeout_secs=$DEFAULT_TIMEOUT
fi
(( timeout_secs > MAX_TIMEOUT )) && timeout_secs=$MAX_TIMEOUT
(( timeout_secs < 60 )) && timeout_secs=60

TASK_SLUG=$(safe_slug "${TASK_NAME%.md}")
[[ -z "$TASK_SLUG" ]] && TASK_SLUG="task"
TASK_TS=$(date +%s)
TASK_SLUG="${TASK_SLUG}-${TASK_TS}"
BRANCH_NAME="smoke/${TASK_SLUG}"
WORKTREE_DIR="$WORKTREE_ROOT/$TASK_SLUG"

if ! git -C "$repo" worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" >/dev/null 2>&1; then
  body=$(mktemp)
  {
    echo "Failed to create git worktree."
    echo "Repo: $repo"
    echo "Branch: $BRANCH_NAME"
  } > "$body"
  write_result "$TASK_NAME" "$BRANCH_NAME" "$WORKTREE_DIR" "${AGENT}-watcher" "FAILED" "$body"
  rm -f "$body"
  budget_increment failures
  archive_task "$TASK_FILE"
  continue
fi

budget_increment runs

# ── Preflight validation ──
if ! preflight_check "$TASK_FILE"; then
  preflight_warnings=$(preflight_get_warnings)
  log "Preflight warnings for $TASK_NAME: $preflight_warnings"
  # Non-fatal — log and continue
fi

TMP_OUT=$(mktemp)
TMP_ERR=$(mktemp)
ENGINE_USED="none"
RUN_RC=1

# ── Run smoke-runner with Claude Sonnet ──
RUNNER="$(dirname "$0")/smoke-runner.sh"
if [[ -x "$RUNNER" ]]; then
  if "$RUNNER" claude "$WORKTREE_DIR" "$TASK_FILE" "$timeout_secs" >"$TMP_OUT" 2>"$TMP_ERR"; then
    ENGINE_USED="claude:claude-sonnet-4-20250514"
    RUN_RC=0
  else
    RUN_RC=$?
  fi
else
  log "ERROR: smoke-runner.sh not found or not executable at $RUNNER"
  echo "smoke-runner.sh not found" > "$TMP_ERR"
fi

# ── Classify failure with typed codes ──
VALIDATION="PASS"
if [[ "$RUN_RC" -ne 0 ]]; then
  error_output=""
  [[ -s "$TMP_ERR" ]] && error_output=$(tail -n 40 "$TMP_ERR")
  failure_code=$(classify_failure "$RUN_RC" "$error_output")
  failure_name=$(_failure_name "$failure_code")

  case "$failure_code" in
    "$FAILURE_TIMEOUT")      VALIDATION="TIMEOUT" ;;
    *)                       VALIDATION="FAILED" ;;
  esac
  [[ "$RUN_RC" -eq 43 ]] && VALIDATION="CONTEXT_OVERFLOW"

  # ── Self-healing: attempt retry ──
  heal_task_id="${task_id:-$TASK_SLUG}"
  heal_decision=$(handle_failure "$heal_task_id" "$failure_code" "$error_output" "$TASK_FILE" 2)
  if [[ "$heal_decision" == "RETRY" ]]; then
    log "Self-healing: retrying $TASK_NAME (failure=$failure_name)"
    RUN_RC=1
    if [[ -x "$RUNNER" ]]; then
      if "$RUNNER" claude "$WORKTREE_DIR" "$TASK_FILE" "$timeout_secs" >"$TMP_OUT" 2>"$TMP_ERR"; then
        ENGINE_USED="claude:claude-sonnet-4-20250514"
        RUN_RC=0
        VALIDATION="PASS"
      else
        RUN_RC=$?
        error_output=""
        [[ -s "$TMP_ERR" ]] && error_output=$(tail -n 40 "$TMP_ERR")
        failure_code=$(classify_failure "$RUN_RC" "$error_output")
        case "$failure_code" in
          "$FAILURE_TIMEOUT")      VALIDATION="TIMEOUT" ;;
          *)                       VALIDATION="FAILED" ;;
        esac
        [[ "$RUN_RC" -eq 43 ]] && VALIDATION="CONTEXT_OVERFLOW"
      fi
    fi
  fi
fi

# ── Build standardized result envelope ──
smoke_output=""
if [[ -s "$TMP_OUT" ]]; then
  smoke_output=$(cat "$TMP_OUT")
fi

BODY=$(mktemp)
{
  dispatch_to=$(json_get "$frontmatter_json" "dispatch_to")
  build_result_envelope "$VALIDATION" \
    "QA run for ${TASK_NAME}" \
    "" \
    "" \
    "${dispatch_to:-}" \
    "${chain_id:-}" \
    "${chain_depth:-0}"
  echo
  echo "Task: $TASK_NAME"
  echo "Repo: $repo"
  echo "Branch: $BRANCH_NAME"
  echo "Worktree: $WORKTREE_DIR"
  echo "Engine: $ENGINE_USED"
  echo "Timeout: ${timeout_secs}s"
  echo
  echo "## QA Output"
  if [[ -n "$smoke_output" ]]; then
    echo "$smoke_output"
  else
    echo "(no output captured)"
  fi
  if [[ -s "$TMP_ERR" ]]; then
    echo
    echo "## Stderr"
    tail -n 80 "$TMP_ERR"
  fi
} > "$BODY"

[[ "$VALIDATION" != "PASS" ]] && budget_increment failures

write_result "$TASK_NAME" "$BRANCH_NAME" "$WORKTREE_DIR" "$ENGINE_USED" "$VALIDATION" "$BODY"

# ── Chaining: dispatch_next if result has dispatch_to ──
if [[ "$VALIDATION" == "PASS" ]]; then
  RESULT_FILE="$OUTBOX/$(ls -1t "$OUTBOX" 2>/dev/null | head -n 1)"
  if [[ -f "$RESULT_FILE" ]]; then
    dispatch_next "$RESULT_FILE" || log "WARNING: dispatch_next failed (rc=$?)"
  fi
fi

# Event-driven: ping Lobster via Discord #command-center
if command -v openclaw >/dev/null 2>&1; then
  status_icon="✅"
  [[ "$VALIDATION" == "FAILED" ]] && status_icon="❌"
  [[ "$VALIDATION" == "TIMEOUT" ]] && status_icon="⏰"
  [[ "$VALIDATION" == "REJECTED" ]] && status_icon="🚫"
  openclaw message send --channel discord -t "${DISCORD_COMMAND_CHANNEL:-}" \
    -m "${status_icon} **Smoke finished:** ${TASK_NAME%.md} — ${VALIDATION}" \
    --silent 2>/dev/null &
  log "Pinged Lobster via Discord #command-center"
fi

# ── Context checkpoint ──
CHECKPOINT_SCRIPT="$HOME/.myndaix/bridge/scripts/write-checkpoint.sh"
if [[ -x "$CHECKPOINT_SCRIPT" ]]; then
  "$CHECKPOINT_SCRIPT" \
    --agent smoke \
    --topic "${subject:-$TASK_NAME}" \
    --completed "${subject:-$TASK_NAME}" \
    --decisions "engine=$ENGINE_USED validation=$VALIDATION" \
    --next "awaiting next dispatch" \
    --task-id "${task_id:-}" \
    >> "$LOG" 2>&1 || log "ERROR: Checkpoint write failed for $TASK_NAME (rc=$?)"
fi

# ── Completion signal ──
COMPLETION_SCRIPT="$HOME/.myndaix/bridge/scripts/write-completion.sh"
if [[ -x "$COMPLETION_SCRIPT" ]]; then
  "$COMPLETION_SCRIPT" \
    --agent smoke \
    --task-id "${task_id:-$TASK_NAME}" \
    --task-name "${subject:-$TASK_NAME}" \
    --result "$VALIDATION" \
    >> "$LOG" 2>&1 || log "ERROR: Completion signal failed for $TASK_NAME (rc=$?)"
fi

rm -f "$BODY" "$TMP_OUT" "$TMP_ERR"
write_heartbeat "$TASK_NAME" "$VALIDATION"
archive_task "$TASK_FILE"
log "Completed task: $TASK_NAME (validation=$VALIDATION, engine=$ENGINE_USED)"

# ── Per-iteration worktree cleanup ──
git -C "$repo" worktree remove "$WORKTREE_DIR" --force >/dev/null 2>&1 || true

DRAIN_COUNT=$((DRAIN_COUNT + 1))
sleep 2  # Brief pause between tasks

done  # ── End drain loop ──

# ── Re-scan: catch files that arrived during processing ──
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
  trap - EXIT
  exec /bin/bash "$0"
done
