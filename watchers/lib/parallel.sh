#!/usr/bin/env bash
# parallel.sh — Parallel task execution library for bridge watchers
# Provides: claim_task_parallel, release_task_parallel, split_task, merge_results, detect_conflicts, track_parallel
#
# Usage: source this file from watchers or runners
# Requires: guardrails.sh (auto-sourced if needed)
#
# No side effects on load — all state changes happen inside function calls.

# ---------------------------------------------------------------------------
# Auto-source guardrails.sh if not already loaded
# ---------------------------------------------------------------------------
_PARALLEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f _sanitize_id >/dev/null 2>&1; then
  source "$_PARALLEL_LIB_DIR/guardrails.sh"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
PARALLEL_STATE_DIR="${BRIDGE_DIR}/state/parallel"
PARALLEL_LOCK_DIR="${BRIDGE_DIR}/state/locks"
MAX_PARALLEL_AGENTS="${MAX_PARALLEL_AGENTS:-3}"
VALID_PARALLEL_AGENTS="mini mack antman"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _par_log <message>
_par_log() {
  if declare -f log >/dev/null 2>&1; then
    log "[parallel] $1"
  else
    printf '[%s] [parallel] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
  fi
}

# _validate_parallel_agent <agent>
# Returns 0 if agent is in the allowed parallel worker list.
_validate_parallel_agent() {
  local agent="$1"
  local valid
  for valid in $VALID_PARALLEL_AGENTS; do
    [[ "$valid" == "$agent" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. claim_task_parallel — atomic lock so only one agent works a subtask
# ---------------------------------------------------------------------------
# Usage: claim_task_parallel <task_id> <agent>
# Returns 0 if lock acquired, 1 if already claimed.
# Lock is a directory (mkdir is atomic on POSIX).
# Writes agent name + timestamp into the lock dir.
# NOTE: renamed from claim_task to avoid colliding with common.sh's
# SQLite-queue claim_task (Upgrade 5). Both functions can now coexist.
claim_task_parallel() {
  local task_id agent
  task_id=$(_sanitize_id "$1")
  agent=$(_sanitize_id "$2")

  if [[ -z "$task_id" || -z "$agent" ]]; then
    _par_log "ERROR: claim_task_parallel requires task_id and agent"
    return 1
  fi

  local lock_dir="${PARALLEL_LOCK_DIR}/${task_id}"

  # Ensure parent exists (not atomic, but the final mkdir is)
  mkdir -p "$PARALLEL_LOCK_DIR" 2>/dev/null

  # mkdir is atomic — first caller wins
  if ! mkdir "$lock_dir" 2>/dev/null; then
    local owner=""
    if [[ -f "${lock_dir}/owner" ]]; then
      owner=$(cat "${lock_dir}/owner")
    fi
    _par_log "Task ${task_id} already claimed by ${owner:-unknown}"
    return 1
  fi

  # Write ownership info
  printf '%s' "$agent" > "${lock_dir}/owner"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "${lock_dir}/claimed_at"

  _par_log "Task ${task_id} claimed by ${agent}"
  return 0
}

# release_task_parallel <task_id> <agent>
# Releases the lock. Only the owning agent can release.
# Returns 0 on success, 1 if not owner or no lock.
# Renamed from release_task to pair with claim_task_parallel.
release_task_parallel() {
  local task_id agent
  task_id=$(_sanitize_id "$1")
  agent=$(_sanitize_id "$2")

  local lock_dir="${PARALLEL_LOCK_DIR}/${task_id}"

  if [[ ! -d "$lock_dir" ]]; then
    _par_log "No lock for ${task_id} — nothing to release"
    return 1
  fi

  local owner=""
  if [[ -f "${lock_dir}/owner" ]]; then
    owner=$(cat "${lock_dir}/owner")
  fi

  if [[ "$owner" != "$agent" ]]; then
    _par_log "ERROR: ${agent} cannot release lock owned by ${owner}"
    return 1
  fi

  rm -rf "$lock_dir"
  _par_log "Task ${task_id} lock released by ${agent}"
  return 0
}

# ---------------------------------------------------------------------------
# 2. split_task — decompose task into subtasks with non-overlapping scope
# ---------------------------------------------------------------------------
# Usage: split_task <task_id> <repo_dir> <agent1> <agent2> ... (max 3)
#
# Reads scope from state/parallel/<task_id>/scope.json (newline-delimited file list)
# Creates subtask files in state/parallel/<task_id>/subtasks/<agent>.md
# Each subtask gets branch name: <agent>/<task_id>
#
# scope.json format (one file path per line):
#   src/foo.sh
#   src/bar.sh
#   lib/baz.sh
#
# Returns 0 on success, 1 on error.
# Prints subtask dir path on stdout.
split_task() {
  local task_id repo_dir
  task_id=$(_sanitize_id "$1")
  repo_dir="$2"
  shift 2

  local agents=()
  while [[ $# -gt 0 ]]; do
    agents+=("$1")
    shift
  done

  local agent_count=${#agents[@]}

  if [[ -z "$task_id" ]]; then
    _par_log "ERROR: split_task requires task_id"
    return 1
  fi

  if [[ ! -d "$repo_dir" ]]; then
    _par_log "ERROR: repo_dir does not exist: $repo_dir"
    return 1
  fi

  if (( agent_count == 0 )); then
    _par_log "ERROR: split_task requires at least one agent"
    return 1
  fi

  if (( agent_count > MAX_PARALLEL_AGENTS )); then
    _par_log "ERROR: ${agent_count} agents exceeds MAX_PARALLEL_AGENTS (${MAX_PARALLEL_AGENTS})"
    return 1
  fi

  # Validate agents
  local a
  for a in "${agents[@]}"; do
    if ! _validate_parallel_agent "$a"; then
      _par_log "ERROR: invalid parallel agent: $a"
      return 1
    fi
  done

  local task_dir="${PARALLEL_STATE_DIR}/${task_id}"
  local scope_file="${task_dir}/scope"
  local subtask_dir="${task_dir}/subtasks"

  mkdir -p "$subtask_dir"

  if [[ ! -f "$scope_file" ]]; then
    _par_log "ERROR: scope file not found: $scope_file"
    return 1
  fi

  # Read file list from scope
  local files=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    files+=("$line")
  done < "$scope_file"

  local file_count=${#files[@]}
  if (( file_count == 0 )); then
    _par_log "ERROR: scope file is empty"
    return 1
  fi

  # Round-robin distribute files to agents (non-overlapping)
  local i=0
  local agent_idx
  for (( i=0; i<file_count; i++ )); do
    agent_idx=$(( i % agent_count ))
    local safe_agent
    safe_agent=$(_sanitize_id "${agents[$agent_idx]}")
    local agent_scope_file="${subtask_dir}/${safe_agent}.scope"
    printf '%s\n' "${files[$i]}" >> "$agent_scope_file"
  done

  # Create subtask metadata files
  for a in "${agents[@]}"; do
    local safe_a
    safe_a=$(_sanitize_id "$a")
    local branch_name="${safe_a}/${task_id}"
    local subtask_file="${subtask_dir}/${safe_a}.md"
    local agent_scope="${subtask_dir}/${safe_a}.scope"

    {
      printf '%s\n' "---"
      printf 'task_id: %s\n' "${task_id}-${safe_a}"
      printf 'parent_task_id: %s\n' "$task_id"
      printf 'agent: %s\n' "$safe_a"
      printf 'branch: %s\n' "$branch_name"
      printf 'repo: %s\n' "$repo_dir"
      printf 'status: pending\n'
      printf 'created: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf '%s\n' "---"
      printf '\n'
      printf '## Scope\n\n'
      if [[ -f "$agent_scope" ]]; then
        while IFS= read -r f; do
          printf '%s\n' "- \`${f}\`"
        done < "$agent_scope"
      fi
      printf '\n'
    } > "$subtask_file"

    _par_log "Created subtask for ${safe_a}: branch=${branch_name}, files=$(wc -l < "$agent_scope" 2>/dev/null || printf '0')"
  done

  # Write agent list
  printf '%s\n' "${agents[@]}" > "${task_dir}/agents"

  printf '%s' "$subtask_dir"
  return 0
}

# ---------------------------------------------------------------------------
# 3. detect_conflicts — check branches for merge conflicts before merging
# ---------------------------------------------------------------------------
# Usage: detect_conflicts <repo_dir> <base_branch> <branch1> <branch2> ...
# Returns 0 if no conflicts, 1 if conflicts found.
# Prints conflict details to stdout.
detect_conflicts() {
  local repo_dir="$1"
  local base_branch="$2"
  shift 2

  local branches=("$@")

  if [[ ! -d "$repo_dir/.git" && ! -f "$repo_dir/.git" ]]; then
    _par_log "ERROR: not a git repo: $repo_dir"
    return 1
  fi

  local has_conflicts=0
  local i j

  # Check each branch pair for conflicts
  for (( i=0; i<${#branches[@]}; i++ )); do
    for (( j=i+1; j<${#branches[@]}; j++ )); do
      local branch_a="${branches[$i]}"
      local branch_b="${branches[$j]}"

      # Validate branch names exist
      if ! git -C "$repo_dir" rev-parse --verify "$branch_a" >/dev/null 2>&1; then
        _par_log "WARNING: branch does not exist: $branch_a"
        continue
      fi
      if ! git -C "$repo_dir" rev-parse --verify "$branch_b" >/dev/null 2>&1; then
        _par_log "WARNING: branch does not exist: $branch_b"
        continue
      fi

      # Use git merge-tree to check for conflicts without touching worktree
      local merge_base
      merge_base=$(git -C "$repo_dir" merge-base "$branch_a" "$branch_b" 2>/dev/null)
      if [[ -z "$merge_base" ]]; then
        _par_log "WARNING: no common ancestor for ${branch_a} and ${branch_b}"
        continue
      fi

      local merge_output
      merge_output=$(git -C "$repo_dir" merge-tree "$merge_base" "$branch_a" "$branch_b" 2>&1)

      # merge-tree outputs conflict markers if there are conflicts
      if printf '%s' "$merge_output" | grep -q "^<<<<<<<"; then
        printf 'CONFLICT between %s and %s:\n' "$branch_a" "$branch_b"
        printf '%s\n\n' "$merge_output"
        has_conflicts=1
      fi
    done
  done

  # Also check each branch against base for fast-forward ability
  for (( i=0; i<${#branches[@]}; i++ )); do
    local branch="${branches[$i]}"
    if ! git -C "$repo_dir" rev-parse --verify "$branch" >/dev/null 2>&1; then
      continue
    fi

    local base_merge
    base_merge=$(git -C "$repo_dir" merge-base "$base_branch" "$branch" 2>/dev/null)
    local base_head
    base_head=$(git -C "$repo_dir" rev-parse "$base_branch" 2>/dev/null)

    if [[ "$base_merge" != "$base_head" ]]; then
      printf 'NOTE: %s has diverged from %s (not fast-forward)\n' "$branch" "$base_branch"
    fi
  done

  if (( has_conflicts )); then
    _par_log "Conflicts detected between agent branches"
    return 1
  fi

  _par_log "No conflicts detected"
  return 0
}

# ---------------------------------------------------------------------------
# 4. merge_results — collect results and attempt merge (or escalate)
# ---------------------------------------------------------------------------
# Usage: merge_results <task_id> <repo_dir> <base_branch>
# Checks all subtask agents, verifies all PASS.
# If all pass + no conflicts: writes merge-ready report to lobster inbox.
# If conflicts or failures: escalates to lobster with details.
# Returns 0 on merge-ready, 1 on escalation.
# NOTE: Never auto-merges. Lobster owns the merge decision.
merge_results() {
  local task_id repo_dir base_branch
  task_id=$(_sanitize_id "$1")
  repo_dir="$2"
  base_branch="${3:-main}"

  local task_dir="${PARALLEL_STATE_DIR}/${task_id}"

  if [[ ! -d "$task_dir" ]]; then
    _par_log "ERROR: no parallel state for task ${task_id}"
    return 1
  fi

  local agents_file="${task_dir}/agents"
  if [[ ! -f "$agents_file" ]]; then
    _par_log "ERROR: no agents file for task ${task_id}"
    return 1
  fi

  # Read agent list
  local agents=()
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    agents+=("$a")
  done < "$agents_file"

  # Check status of all subtasks
  local all_pass=1
  local branches=()
  local failed_agents=()
  local pending_agents=()

  for a in "${agents[@]}"; do
    local safe_a
    safe_a=$(_sanitize_id "$a")
    local status_file="${task_dir}/subtasks/${safe_a}.status"
    local branch_name="${safe_a}/${task_id}"

    if [[ ! -f "$status_file" ]]; then
      pending_agents+=("$safe_a")
      all_pass=0
      continue
    fi

    local status
    status=$(cat "$status_file")

    case "$status" in
      PASS|pass|complete)
        branches+=("$branch_name")
        ;;
      FAIL|fail|error)
        failed_agents+=("$safe_a")
        all_pass=0
        ;;
      *)
        pending_agents+=("$safe_a")
        all_pass=0
        ;;
    esac
  done

  # If pending subtasks remain, not ready
  if (( ${#pending_agents[@]} > 0 )); then
    _par_log "Task ${task_id}: waiting on agents: ${pending_agents[*]}"
    # Update tracking
    _write_tracking "$task_id" "pending" "Waiting on: ${pending_agents[*]}"
    return 1
  fi

  # If any failed, escalate
  if (( ${#failed_agents[@]} > 0 )); then
    _par_log "Task ${task_id}: failed agents: ${failed_agents[*]}"
    _escalate_parallel "$task_id" "Subtask failures" \
      "Agents failed: ${failed_agents[*]}" "$repo_dir"
    _write_tracking "$task_id" "failed" "Failed agents: ${failed_agents[*]}"
    return 1
  fi

  # All passed — check for conflicts between branches
  if (( ${#branches[@]} > 1 )); then
    local conflict_output
    conflict_output=$(detect_conflicts "$repo_dir" "$base_branch" "${branches[@]}" 2>&1)
    local conflict_rc=$?

    if (( conflict_rc != 0 )); then
      _par_log "Task ${task_id}: merge conflicts detected — escalating"
      _escalate_parallel "$task_id" "Merge conflicts" \
        "$conflict_output" "$repo_dir"
      _write_tracking "$task_id" "conflicts" "Merge conflicts between agent branches"
      return 1
    fi
  fi

  # All pass, no conflicts — notify Lobster for merge
  _notify_merge_ready "$task_id" "$repo_dir" "$base_branch" "${branches[@]}"
  _write_tracking "$task_id" "merge-ready" "All subtasks passed, no conflicts"
  _par_log "Task ${task_id}: all subtasks passed, merge-ready — notified Lobster"
  return 0
}

# ---------------------------------------------------------------------------
# 5. track_parallel — state tracking for subtask progress
# ---------------------------------------------------------------------------
# Usage: track_parallel <task_id> <action> [args...]
# Actions:
#   status                — print current status of all subtasks
#   update <agent> <status> — update subtask status (pending|pass|fail)
#   summary               — one-line summary
#
# Returns 0 on success, 1 on error.
track_parallel() {
  local task_id action
  task_id=$(_sanitize_id "$1")
  action="$2"
  shift 2

  local task_dir="${PARALLEL_STATE_DIR}/${task_id}"

  if [[ ! -d "$task_dir" ]]; then
    _par_log "ERROR: no parallel state for ${task_id}"
    return 1
  fi

  case "$action" in
    status)
      _track_status "$task_id"
      ;;
    update)
      local agent="$1"
      local status="$2"
      _track_update "$task_id" "$agent" "$status"
      ;;
    summary)
      _track_summary "$task_id"
      ;;
    *)
      _par_log "ERROR: unknown track_parallel action: $action"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Internal: tracking helpers
# ---------------------------------------------------------------------------

# _track_status <task_id>
_track_status() {
  local task_id="$1"
  local task_dir="${PARALLEL_STATE_DIR}/${task_id}"
  local agents_file="${task_dir}/agents"

  if [[ ! -f "$agents_file" ]]; then
    printf 'No agents registered for %s\n' "$task_id"
    return 1
  fi

  printf 'Task: %s\n' "$task_id"
  printf 'Subtasks:\n'

  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    local safe_a
    safe_a=$(_sanitize_id "$a")
    local status_file="${task_dir}/subtasks/${safe_a}.status"
    local status="pending"
    if [[ -f "$status_file" ]]; then
      status=$(cat "$status_file")
    fi
    printf '  %s: %s\n' "$safe_a" "$status"
  done < "$agents_file"

  # Overall tracking status
  local tracking_file="${task_dir}/tracking"
  if [[ -f "$tracking_file" ]]; then
    printf 'Overall: %s\n' "$(cat "$tracking_file")"
  fi
}

# _track_update <task_id> <agent> <status>
_track_update() {
  local task_id="$1"
  local agent
  agent=$(_sanitize_id "$2")
  local status="$3"

  # Validate status
  case "$status" in
    pending|pass|fail|PASS|FAIL|complete|error) ;;
    *)
      _par_log "ERROR: invalid status: $status"
      return 1
      ;;
  esac

  local task_dir="${PARALLEL_STATE_DIR}/${task_id}"
  local subtask_dir="${task_dir}/subtasks"
  mkdir -p "$subtask_dir"

  printf '%s' "$status" > "${subtask_dir}/${agent}.status"
  _par_log "Task ${task_id}: agent ${agent} status -> ${status}"
  return 0
}

# _track_summary <task_id>
_track_summary() {
  local task_id="$1"
  local task_dir="${PARALLEL_STATE_DIR}/${task_id}"
  local agents_file="${task_dir}/agents"

  if [[ ! -f "$agents_file" ]]; then
    printf 'unknown\n'
    return 1
  fi

  local total=0 passed=0 failed=0 pending=0

  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    local safe_a
    safe_a=$(_sanitize_id "$a")
    local status_file="${task_dir}/subtasks/${safe_a}.status"
    local status="pending"
    if [[ -f "$status_file" ]]; then
      status=$(cat "$status_file")
    fi
    (( total++ ))
    case "$status" in
      PASS|pass|complete) (( passed++ )) ;;
      FAIL|fail|error)    (( failed++ )) ;;
      *)                  (( pending++ )) ;;
    esac
  done < "$agents_file"

  printf '%s: %d/%d passed, %d failed, %d pending\n' \
    "$task_id" "$passed" "$total" "$failed" "$pending"
}

# _write_tracking <task_id> <status> <detail>
_write_tracking() {
  local task_id="$1"
  local status="$2"
  local detail="$3"
  local task_dir="${PARALLEL_STATE_DIR}/${task_id}"
  mkdir -p "$task_dir"
  printf '%s | %s | %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$status" "$detail" > "${task_dir}/tracking"
}

# ---------------------------------------------------------------------------
# Internal: escalation + notification
# ---------------------------------------------------------------------------

# _escalate_parallel <task_id> <subject> <detail> <repo_dir>
_escalate_parallel() {
  local task_id="$1"
  local subject="$2"
  local detail="$3"
  local repo_dir="${4:-}"

  local lobster_inbox="${BRIDGE_DIR}/inbox/lobster"
  mkdir -p "$lobster_inbox"

  local safe_task_id
  safe_task_id=$(_sanitize_id "$task_id")
  local ts
  ts=$(date -u '+%Y%m%d%H%M%S')
  local safe_subject
  safe_subject=$(printf '%s' "$subject" | tr -cd 'a-zA-Z0-9 ._:/-')
  local safe_detail
  safe_detail=$(printf '%s' "$detail" | tr -d '\000-\010\013\014\016-\037')
  safe_detail="${safe_detail:0:4000}"

  local alert_file="${lobster_inbox}/${ts}-parallel-${safe_task_id}.md"

  {
    printf '%s\n' "---"
    printf '%s\n' "from: mini"
    printf '%s\n' "to: lobster"
    printf '%s\n' "type: alert"
    printf 'subject: "Parallel task issue: %s"\n' "$safe_subject"
    printf 'task_id: %s\n' "$safe_task_id"
    printf 'created: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "tier: auto"
    printf '%s\n' "---"
    printf '\n'
    printf '## Parallel Execution Alert\n\n'
    printf '**Task:** %s\n' "$safe_task_id"
    printf '**Issue:** %s\n\n' "$safe_subject"
    printf '## Details\n\n'
    printf '%s\n' "$safe_detail"
    if [[ -n "$repo_dir" ]]; then
      printf '\n**Repo:** %s\n' "$repo_dir"
    fi
  } > "$alert_file"

  _par_log "Escalated parallel task ${task_id} to lobster: ${alert_file}"
}

# _notify_merge_ready <task_id> <repo_dir> <base_branch> <branches...>
_notify_merge_ready() {
  local task_id="$1"
  local repo_dir="$2"
  local base_branch="$3"
  shift 3
  local branches=("$@")

  local lobster_inbox="${BRIDGE_DIR}/inbox/lobster"
  mkdir -p "$lobster_inbox"

  local safe_task_id
  safe_task_id=$(_sanitize_id "$task_id")
  local ts
  ts=$(date -u '+%Y%m%d%H%M%S')

  local notify_file="${lobster_inbox}/${ts}-merge-ready-${safe_task_id}.md"

  {
    printf '%s\n' "---"
    printf '%s\n' "from: mini"
    printf '%s\n' "to: lobster"
    printf '%s\n' "type: merge-request"
    printf 'subject: "Parallel task ready to merge: %s"\n' "$safe_task_id"
    printf 'task_id: %s\n' "$safe_task_id"
    printf 'base_branch: %s\n' "$base_branch"
    printf 'created: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "tier: auto"
    printf '%s\n' "---"
    printf '\n'
    printf '## Merge Ready\n\n'
    printf '**Task:** %s\n' "$safe_task_id"
    printf '**Base:** %s\n' "$base_branch"
    printf '**Repo:** %s\n\n' "$repo_dir"
    printf '### Branches to merge\n\n'
    local b
    for b in "${branches[@]}"; do
      printf '- `%s`\n' "$b"
    done
    printf '\n'
    printf '%s\n' "All subtasks passed. No conflicts detected."
    printf '%s\n' "Lobster: review and merge at your discretion."
  } > "$notify_file"

  _par_log "Merge-ready notification sent for ${task_id}"
}

# ---------------------------------------------------------------------------
# Exports — all functions available when sourced
# ---------------------------------------------------------------------------
export -f claim_task_parallel
export -f release_task_parallel
export -f split_task
export -f detect_conflicts
export -f merge_results
export -f track_parallel
export -f _par_log
export -f _validate_parallel_agent
