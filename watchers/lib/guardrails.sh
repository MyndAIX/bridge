#!/usr/bin/env bash
# guardrails.sh — shared guardrail library for bridge watchers
# Source this file: source "$(dirname "$0")/lib/guardrails.sh"

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
GUARDRAIL_STATE_DIR="${BRIDGE_DIR}/state"
GUARDRAIL_DEAD_LETTER_DIR="${BRIDGE_DIR}/dead-letter"

# ---------------------------------------------------------------------------
# 0. Shared Sanitizers
# ---------------------------------------------------------------------------
# _sanitize_id <id>
# Strips path traversal and dangerous chars for safe filesystem use.
# Used by all libs for task_id, chain_id, or any untrusted ID in file paths.
_sanitize_id() {
  local id="$1"
  id="${id//[\/\\]/_}"
  id="${id//../_}"
  id=$(printf '%s' "$id" | tr -cd 'a-zA-Z0-9._-')
  printf '%s' "${id:0:200}"
}

# ---------------------------------------------------------------------------
# 1. Retry Budget
# ---------------------------------------------------------------------------
# Usage: check_retry_budget <task_id> <max_retries>
# Returns 0 if retries remain, 1 if exhausted.
# Side effect: increments the counter each call.
check_retry_budget() {
  local task_id
  task_id=$(_sanitize_id "$1")
  local max_retries="$2"
  local dir="${GUARDRAIL_STATE_DIR}/retries"
  local file="${dir}/${task_id}.count"

  mkdir -p "$dir"

  local count=0
  if [[ -f "$file" ]]; then
    count=$(cat "$file")
    # Guard against corrupt/empty file
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
      count=0
    fi
  fi

  if (( count >= max_retries )); then
    return 1
  fi

  echo $(( count + 1 )) > "$file"
  return 0
}

# ---------------------------------------------------------------------------
# 2. Dedupe Guard
# ---------------------------------------------------------------------------
# Usage: check_dedupe <task_id>
# Returns 0 if task is new, 1 if already processed.
# Auto-expires after 24h.
check_dedupe() {
  local task_id
  task_id=$(_sanitize_id "$1")
  local dir="${GUARDRAIL_STATE_DIR}/dedupe"
  local file="${dir}/${task_id}.done"

  mkdir -p "$dir"

  if [[ -f "$file" ]]; then
    local now
    now=$(date +%s)
    local file_age
    # macOS stat vs GNU stat
    if stat -f %m "$file" &>/dev/null; then
      file_age=$(stat -f %m "$file")
    else
      file_age=$(stat -c %Y "$file")
    fi
    local age_seconds=$(( now - file_age ))
    if (( age_seconds < 86400 )); then
      return 1  # Already processed within 24h
    fi
    # Expired — remove and treat as new
    rm -f "$file"
  fi

  touch "$file"
  return 0
}

# ---------------------------------------------------------------------------
# 3. Chain Depth Limit
# ---------------------------------------------------------------------------
# Usage: check_chain_depth <chain_id> <max_depth>
# Returns 0 if under limit, 1 if at max.
# Tracks depth in state file; call reset_chain_depth to clear.
check_chain_depth() {
  local chain_id
  chain_id=$(_sanitize_id "$1")
  local max_depth="$2"
  local dir="${GUARDRAIL_STATE_DIR}/chains"
  local file="${dir}/${chain_id}.depth"

  mkdir -p "$dir"

  local depth=0
  if [[ -f "$file" ]]; then
    depth=$(cat "$file")
    if ! [[ "$depth" =~ ^[0-9]+$ ]]; then
      depth=0
    fi
  fi

  if (( depth >= max_depth )); then
    return 1
  fi

  echo $(( depth + 1 )) > "$file"
  return 0
}

# ---------------------------------------------------------------------------
# 4. Context Sanitizer
# ---------------------------------------------------------------------------
# Usage: sanitize_context <input_file> <output_file>
# Strips dangerous tags, control chars, caps at 2000 chars,
# removes frontmatter-like content (---) from body.
sanitize_context() {
  local input_file="$1"
  local output_file="$2"

  if [[ ! -f "$input_file" ]]; then
    echo "" > "$output_file"
    return 0
  fi

  local content
  content=$(cat "$input_file")

  # Strip </user_input> and <user_input> tags (and variants)
  content=$(printf '%s' "$content" | sed -E 's|</?user_input[^>]*>||g')

  # Strip control characters (keep newline, tab, carriage return)
  content=$(printf '%s' "$content" | tr -d '\000-\010\013\014\016-\037')

  # Remove frontmatter blocks (--- ... ---) from body
  # Only strip if content starts with ---
  content=$(printf '%s' "$content" | sed -E '/^---$/,/^---$/d')

  # Cap at 2000 characters
  content=$(printf '%s' "$content" | head -c 2000)

  printf '%s' "$content" > "$output_file"
  return 0
}

# ---------------------------------------------------------------------------
# 5. Dead Letter Queue
# ---------------------------------------------------------------------------
# Usage: dead_letter <task_file> <reason>
# Moves task to dead-letter dir with a companion .reason file.
dead_letter() {
  local task_file="$1"
  local reason="$2"

  mkdir -p "$GUARDRAIL_DEAD_LETTER_DIR"

  local basename
  basename=$(basename "$task_file")
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local dest="${GUARDRAIL_DEAD_LETTER_DIR}/${timestamp}_${basename}"

  if [[ -f "$task_file" ]]; then
    mv "$task_file" "$dest"
  else
    # File already gone — create a placeholder
    echo "[original file missing: ${task_file}]" > "$dest"
  fi

  echo "$reason" > "${dest}.reason"
  echo "[dead-letter] ${basename}: ${reason}" >&2
  return 0
}
