#!/bin/bash
# oracle-watcher.sh — Oracle architecture reviewer watcher
# Processes review requests from Oracle's inbox using Gemini 2.5 Pro

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Configuration
BRIDGE_DIR="$HOME/.myndaix/bridge"
ORACLE_INBOX="$BRIDGE_DIR/inbox/oracle"
PROCESSED_DIR="$BRIDGE_DIR/processed"
LOCK_DIR="$BRIDGE_DIR/locks"
LOG_FILE="$BRIDGE_DIR/watchers/oracle-watcher.log"
AGENT_NAME="oracle"

# Runtime state
TASK_CAP_PER_DAY=30
FAILURE_CAP_PER_DAY=5
STALE_LOCK_TIMEOUT=900  # 15 minutes

# Ensure directories exist
mkdir -p "$ORACLE_INBOX" "$PROCESSED_DIR" "$LOCK_DIR" "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [oracle] $*" >> "$LOG_FILE"
}

# Release lock on exit
release_lock() {
  if [[ -n "${LOCK_ACQUIRED:-}" ]]; then
    rmdir "$LOCK_ACQUIRED" 2>/dev/null || true
    unset LOCK_ACQUIRED
  fi
}

trap 'release_lock' EXIT INT TERM

# Daily task counter check
check_daily_limits() {
  local today=$(date '+%Y%m%d')
  local count_file="$LOCK_DIR/oracle-daily-$today"
  local failure_file="$LOCK_DIR/oracle-failures-$today"

  local task_count=0 failure_count=0

  if [[ -f "$count_file" ]]; then
    task_count=$(cat "$count_file" 2>/dev/null || echo 0)
  fi

  if [[ -f "$failure_file" ]]; then
    failure_count=$(cat "$failure_file" 2>/dev/null || echo 0)
  fi

  if [[ $task_count -ge $TASK_CAP_PER_DAY ]]; then
    log "Daily task cap reached ($task_count/$TASK_CAP_PER_DAY)"
    return 1
  fi

  if [[ $failure_count -ge $FAILURE_CAP_PER_DAY ]]; then
    log "Daily failure cap reached ($failure_count/$FAILURE_CAP_PER_DAY)"
    return 1
  fi

  return 0
}

increment_counter() {
  local today=$(date '+%Y%m%d')
  local count_file="$LOCK_DIR/oracle-daily-$today"
  local current=0

  if [[ -f "$count_file" ]]; then
    current=$(cat "$count_file" 2>/dev/null || echo 0)
  fi

  echo $((current + 1)) > "$count_file"
}

increment_failure() {
  local today=$(date '+%Y%m%d')
  local failure_file="$LOCK_DIR/oracle-failures-$today"
  local current=0

  if [[ -f "$failure_file" ]]; then
    current=$(cat "$failure_file" 2>/dev/null || echo 0)
  fi

  echo $((current + 1)) > "$failure_file"
}

# Acquire process lock
acquire_lock() {
  local lock_dir="$LOCK_DIR/oracle-watcher"

  # Check for stale locks
  if [[ -d "$lock_dir" ]]; then
    local lock_age=$(($(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || echo 0)))
    if [[ $lock_age -gt $STALE_LOCK_TIMEOUT ]]; then
      log "Removing stale lock (age: ${lock_age}s)"
      rmdir "$lock_dir" 2>/dev/null || true
    fi
  fi

  # Try to acquire lock
  if mkdir "$lock_dir" 2>/dev/null; then
    LOCK_ACQUIRED="$lock_dir"
    return 0
  else
    return 1
  fi
}

# Fix Oracle wrong-branch bug: resolve Mini auto-branch to feature branch
resolve_feature_branch() {
  local branch="$1"
  local task_file="$2"

  # If branch doesn't start with mini/ or antman/, use as-is
  if [[ ! "$branch" =~ ^(mini|antman)/ ]]; then
    echo "$branch"
    return 0
  fi

  log "Auto-branch detected: $branch, resolving to feature branch"

  # Extract task ID from auto-branch name
  # Format: mini/20260323230300-lobster-task-scraper-phase1-1774332270
  # We want: 20260323230300-lobster-task-scraper-phase1
  local task_id_candidate=""
  if [[ "$branch" =~ ^(mini|antman)/(.+)-[0-9]+$ ]]; then
    task_id_candidate="${BASH_REMATCH[2]}"
  else
    log "WARNING: Cannot parse auto-branch format: $branch"
    echo "$branch"
    return 0
  fi

  # Look for original task in processed directory
  local original_task=""
  for pattern in "${task_id_candidate}.md" "*${task_id_candidate}*.md"; do
    if [[ -f "$PROCESSED_DIR/$pattern" ]]; then
      original_task="$PROCESSED_DIR/$pattern"
      break
    fi
  done

  # If no original task found, check for branch field in current review request
  if [[ -z "$original_task" && -f "$task_file" ]]; then
    local extracted_branch=""
    extracted_branch=$(awk '/^---$/{c++; if(c==2) exit} c==1 && /^branch:/{gsub(/^branch:[[:space:]]*/, ""); print; exit}' "$task_file" 2>/dev/null || echo "")
    if [[ -n "$extracted_branch" && "$extracted_branch" != "$branch" ]]; then
      log "Using branch from review request: $extracted_branch"
      echo "$extracted_branch"
      return 0
    fi
  fi

  if [[ -n "$original_task" ]]; then
    # Try to extract branch from original task frontmatter
    local feature_branch=""
    feature_branch=$(awk '/^---$/{c++; if(c==2) exit} c==1 && /^branch:/{gsub(/^branch:[[:space:]]*/, ""); print; exit}' "$original_task" 2>/dev/null || echo "")

    if [[ -n "$feature_branch" && ! "$feature_branch" =~ ^(mini|antman)/ ]]; then
      log "Resolved to feature branch: $feature_branch (from $original_task)"
      echo "$feature_branch"
      return 0
    else
      log "No feature branch found in original task"
    fi
  fi

  log "ERROR: Could not resolve feature branch - no valid feature branch found"
  return 1
}

# Parse YAML frontmatter safely
parse_frontmatter() {
  local file="$1"
  local field="$2"

  awk -v field="$field" '
    /^---$/ {c++; if(c==2) exit}
    c==1 && $0 ~ "^" field ":" {
      gsub("^" field ":[[:space:]]*", "")
      gsub(/^["'"'"']/, ""); gsub(/["'"'"']$/, "")
      print
      exit
    }
  ' "$file"
}

# Extract task body (after frontmatter)
extract_body() {
  awk '/^---$/{c++; if(c==2){found=1; next}} found{print}' "$1"
}

# Write failure result back to sender
write_failure_result() {
  local from_agent="$1"
  local task_id="$2"
  local subject="$3"
  local reason="$4"

  # Sanitize from_agent field (BUG 2 fix)
  local allowed_agents=("lobster" "mini" "mack" "antman" "kilabz" "oracle" "recon" "harley" "jefe" "cli")
  local agent_allowed=false

  for allowed in "${allowed_agents[@]}"; do
    if [[ "$from_agent" == "$allowed" ]]; then
      agent_allowed=true
      break
    fi
  done

  if [[ "$agent_allowed" != "true" ]] || [[ "$from_agent" =~ [./] ]]; then
    log "ERROR: Invalid from_agent value: $from_agent (potential path traversal)"
    return 1
  fi

  local result_timestamp=$(date -u '+%Y%m%d%H%M%S')
  local result_suffix=$(head -c 4 /dev/urandom | xxd -p | cut -c1-8)
  local result_file="$BRIDGE_DIR/inbox/$from_agent/${result_timestamp}-oracle-result-${result_suffix}.md"

  # Write failure result
  {
    echo "---"
    echo "from: oracle"
    echo "to: $from_agent"
    echo "type: result"
    echo "status: fail"
    echo "subject: \"Oracle review failed: $subject\""
    echo "task_id: ${task_id:-unknown}"
    echo "created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "---"
    echo ""
    echo "# Review Failed"
    echo ""
    echo "**Reason:** $reason"
    echo ""
    echo "This task was rejected to prevent incorrect review. Please fix the issue and resubmit."
  } > "$result_file"

  log "Failure result written to: $result_file"
}

# Generate Oracle review prompt
generate_review_prompt() {
  local repo="$1"
  local branch="$2"
  local task_name="$3"
  local body="$4"

  cat <<PROMPT
You are Oracle, the architecture reviewer for the MyndAIX agent system. Your role is to provide third-eye security and architecture review with fresh perspective.

**Repository:** $repo
**Branch:** $branch
**Task:** $task_name

Review the code changes on this branch for:

1. **Security vulnerabilities** - injection risks, privilege escalation, data exposure
2. **Architecture concerns** - design patterns, separation of concerns, maintainability
3. **Integration risks** - breaking changes, backward compatibility, deployment concerns
4. **Performance implications** - bottlenecks, resource usage, scalability
5. **Blind spots** - edge cases the builder might have missed

Focus on code quality and architectural soundness. Be specific with file:line references.

## Review Request Details

$body

## Review Format

Provide:
- **RISK LEVEL:** Low/Medium/High/Critical
- **KEY FINDINGS:** Bullet list of specific issues
- **RECOMMENDATIONS:** Concrete next steps
- **APPROVAL STATUS:** Approved/Needs Changes/Rejected

Be direct and actionable. Flag anything that could cause production issues.
PROMPT
}

# Process a single review task
process_review() {
  local task_file="$1"
  local task_name=$(basename "$task_file" .md)

  log "Processing review: $task_name"

  # Parse frontmatter
  local from_agent=$(parse_frontmatter "$task_file" "from")
  local subject=$(parse_frontmatter "$task_file" "subject")
  local repo=$(parse_frontmatter "$task_file" "repo")
  local branch=$(parse_frontmatter "$task_file" "branch")
  local task_id=$(parse_frontmatter "$task_file" "task_id")
  local objective=$(parse_frontmatter "$task_file" "objective")

  # Validate required fields
  if [[ -z "$from_agent" || -z "$subject" ]]; then
    log "ERROR: Missing required fields in $task_file"
    return 1
  fi

  # BUG 2 FIX: Early validation of from_agent field
  if [[ ! "$from_agent" =~ ^(lobster|mini|mack|antman|kilabz|oracle|recon|harley|jefe)$ ]]; then
    log "ERROR: Invalid from_agent value: $from_agent (not in allowlist)"
    return 1
  fi

  # Extract task body
  local body=$(extract_body "$task_file")

  # Resolve feature branch if needed - FAIL CLOSED if no branch
  local resolved_branch=""
  if [[ -n "$branch" ]]; then
    if ! resolved_branch=$(resolve_feature_branch "$branch" "$task_file"); then
      # BUG 1 FIX: FAIL CLOSED when branch resolution fails
      log "ERROR: Branch resolution failed for branch $branch - failing closed"
      echo "ERROR: Branch resolution failed for $branch in task $task_id" >&2
      write_failure_result "$from_agent" "$task_id" "$subject" "branch_unresolved"
      return 1
    fi
  else
    log "ERROR: No branch specified in task - failing closed"
    echo "ERROR: No branch specified in task $task_id" >&2
    write_failure_result "$from_agent" "$task_id" "$subject" "No branch specified - reviews require explicit branch"
    return 1
  fi

  # Validate repo path
  if [[ -z "$repo" ]]; then
    log "ERROR: No repo specified in $task_file"
    return 1
  fi

  local expanded_repo="${repo/#\~/$HOME}"
  if [[ ! -d "$expanded_repo" ]]; then
    log "ERROR: Repository not found: $expanded_repo"
    return 1
  fi

  # Check if repo is a git repository
  if [[ ! -d "$expanded_repo/.git" ]]; then
    log "ERROR: Not a git repository: $expanded_repo"
    return 1
  fi

  # Create temporary worktree for isolated review
  local timestamp=$(date -u '+%Y%m%d%H%M%S')
  local suffix=$(head -c 4 /dev/urandom | xxd -p | cut -c1-8)
  local worktree_path="/tmp/oracle-review-${timestamp}-${suffix}"

  log "Creating worktree: $worktree_path for branch: $resolved_branch"

  # Clean up worktree on exit
  cleanup_worktree() {
    if [[ -d "$worktree_path" ]]; then
      cd "$HOME"  # Exit worktree before cleanup
      git -C "$expanded_repo" worktree remove --force "$worktree_path" 2>/dev/null || true
      rm -rf "$worktree_path" 2>/dev/null || true
    fi
  }

  trap cleanup_worktree RETURN

  # Create git worktree
  if ! git -C "$expanded_repo" worktree add "$worktree_path" "$resolved_branch" 2>/dev/null; then
    # Branch might not exist, try creating it from main
    log "Branch $resolved_branch not found, checking if it exists remotely"

    # Fetch latest changes
    git -C "$expanded_repo" fetch --all 2>/dev/null || true

    # Try checking out from origin
    if git -C "$expanded_repo" worktree add "$worktree_path" "origin/$resolved_branch" 2>/dev/null; then
      log "Checked out remote branch: origin/$resolved_branch"
    else
      # BUG 1 FIX: FAIL CLOSED instead of falling back to main
      log "ERROR: Branch $resolved_branch not found locally or remotely - failing closed"
      echo "ERROR: Branch $resolved_branch not found for task $task_id" >&2
      write_failure_result "$from_agent" "$task_id" "$subject" "Branch $resolved_branch not found - cannot review non-existent branch"
      return 1
    fi
  fi

  # Change to worktree for review
  cd "$worktree_path"

  # Generate review prompt
  local review_prompt
  review_prompt=$(generate_review_prompt "$repo" "$resolved_branch" "$subject" "$body")

  # Run Gemini review
  local result_content=""
  local gemini_cmd="gemini"

  # Check if Gemini CLI is available
  if ! command -v gemini >/dev/null 2>&1; then
    log "ERROR: Gemini CLI not found. Please install the Gemini CLI tool."
    echo "Review failed: Gemini CLI not available"
    return 1
  fi

  log "Running Gemini architecture review..."

  # Run Gemini with timeout and error handling
  if ! result_content=$(echo "$review_prompt" | timeout 300 gemini -m gemini-2.5-pro-latest 2>&1); then
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
      log "ERROR: Gemini review timed out"
      result_content="ERROR: Review timed out after 5 minutes"
    else
      log "ERROR: Gemini review failed with exit code $exit_code"
      result_content="ERROR: Gemini review failed\n\n$result_content"
    fi
  fi

  # Generate result file - sanitize from_agent (BUG 2 fix)
  local allowed_agents=("lobster" "mini" "mack" "antman" "kilabz" "oracle" "recon" "harley" "jefe" "cli")
  local agent_allowed=false

  for allowed in "${allowed_agents[@]}"; do
    if [[ "$from_agent" == "$allowed" ]]; then
      agent_allowed=true
      break
    fi
  done

  if [[ "$agent_allowed" != "true" ]] || [[ "$from_agent" =~ [./] ]]; then
    log "ERROR: Invalid from_agent value: $from_agent (potential path traversal)"
    return 1
  fi

  local result_timestamp=$(date -u '+%Y%m%d%H%M%S')
  local result_suffix=$(head -c 4 /dev/urandom | xxd -p | cut -c1-8)
  local result_file="$BRIDGE_DIR/inbox/$from_agent/${result_timestamp}-oracle-result-${result_suffix}.md"

  # Write review result
  {
    echo "---"
    echo "from: oracle"
    echo "to: $from_agent"
    echo "type: result"
    echo "subject: \"Oracle review: $subject\""
    echo "task_id: ${task_id:-$task_name}"
    echo "repo: $repo"
    echo "branch: $resolved_branch"
    echo "reviewer: gemini-2.5-pro-latest"
    echo "created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "---"
    echo ""
    echo "# Oracle Architecture Review"
    echo ""
    echo "**Original Request:** $subject"
    echo "**Repository:** $repo"
    echo "**Branch Reviewed:** $resolved_branch"
    echo "**Requested by:** $from_agent"
    echo ""
    echo "$result_content"
  } > "$result_file"

  log "Review complete, result written to: $result_file"

  # Move processed task to archive
  local archive_file="$PROCESSED_DIR/$task_name"
  mv "$task_file" "$archive_file"

  log "Task archived: $archive_file"
  increment_counter

  return 0
}

# Main processing loop (single iteration)
process_inbox() {
  if ! check_daily_limits; then
    return 0
  fi

  # Find oldest .md file in Oracle inbox (skip .tmp and .syncthing.*)
  local oldest_task=""
  for task_file in "$ORACLE_INBOX"/*.md; do
    [[ ! -f "$task_file" ]] && continue

    local basename=$(basename "$task_file")

    # Skip temporary and syncthing files
    [[ "$basename" =~ ^\.tmp ]] && continue
    [[ "$basename" =~ \.syncthing\. ]] && continue

    # Take first valid file (ls sorts by name, which includes timestamp)
    oldest_task="$task_file"
    break
  done

  # No tasks to process
  if [[ -z "$oldest_task" ]]; then
    return 0
  fi

  # Process the task
  if process_review "$oldest_task"; then
    log "Successfully processed: $(basename "$oldest_task")"
    return 0
  else
    log "Failed to process: $(basename "$oldest_task")"
    increment_failure
    return 1
  fi
}

# Main entry point
main() {
  # Try to acquire lock
  if ! acquire_lock; then
    exit 0  # Another instance running, exit silently
  fi

  log "Oracle watcher started (PID $$)"

  # Process inbox once
  process_inbox

  log "Oracle watcher cycle complete"
}

# Run main function
main "$@"