#!/bin/bash
# chaining.sh — Task chain management for bridge pipeline
# Provides: dispatch_next, build_chain_task
#
# Usage: source this file from watchers after sourcing context.sh
# Requires: python3, context.sh (sourced first)

BRIDGE_ROOT="${BRIDGE_ROOT:-$HOME/.myndaix/bridge}"
MAX_CHAIN_DEPTH="${MAX_CHAIN_DEPTH:-5}"
VALID_AGENTS="mini mack antman kilabz lobster harley cli"

# Source context.sh from same directory if not already loaded
CHAINING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f extract_context >/dev/null 2>&1; then
  source "$CHAINING_LIB_DIR/context.sh"
fi
if ! declare -f _sanitize_id >/dev/null 2>&1; then
  source "$CHAINING_LIB_DIR/guardrails.sh"
fi

# _chain_log <message>
# Internal logging helper — uses caller's log() if available, else stderr.
_chain_log() {
  if declare -f log >/dev/null 2>&1; then
    log "[chaining] $1"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [chaining] $1" >&2
  fi
}

# _validate_agent <agent_name>
# Returns 0 if agent name is valid, 1 otherwise.
_validate_agent() {
  local agent="$1"
  local valid
  for valid in $VALID_AGENTS; do
    [[ "$valid" == "$agent" ]] && return 0
  done
  return 1
}

# dispatch_next <result_file>
# Reads dispatch_to from result frontmatter.
# If present: creates new task in target agent's inbox.
# Carries forward: chain_id, chain_depth+1, context block.
# If absent: chain complete, no action.
# Returns: 0 on dispatch or no-op, 1 on error.
dispatch_next() {
  local result_file="$1"

  if [[ ! -f "$result_file" ]]; then
    _chain_log "ERROR: result file not found: $result_file"
    return 1
  fi

  # Parse frontmatter to get dispatch_to, chain_id, chain_depth
  local fm_json
  fm_json=$(python3 -c '
import sys, re, json
content = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", content, re.DOTALL)
if not m:
    print("{}")
    sys.exit(0)
try:
    import yaml
    data = yaml.safe_load(m.group(1)) or {}
    print(json.dumps(data, default=str))
except Exception:
    print("{}")
' "$result_file" 2>/dev/null) || fm_json="{}"

  local dispatch_to chain_id chain_depth status
  dispatch_to=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('dispatch_to',''))" "$fm_json" 2>/dev/null)
  chain_id=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('chain_id',''))" "$fm_json" 2>/dev/null)
  chain_depth=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('chain_depth',0))" "$fm_json" 2>/dev/null)
  status=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('status',''))" "$fm_json" 2>/dev/null)

  # No dispatch_to = chain complete
  if [[ -z "$dispatch_to" ]]; then
    _chain_log "No dispatch_to in result — chain complete"
    return 0
  fi

  # Validate target agent
  if ! _validate_agent "$dispatch_to"; then
    _chain_log "ERROR: invalid dispatch target: $dispatch_to"
    return 1
  fi

  # Depth check
  local next_depth=$(( ${chain_depth:-0} + 1 ))
  if (( next_depth > MAX_CHAIN_DEPTH )); then
    _chain_log "ERROR: chain depth $next_depth exceeds max $MAX_CHAIN_DEPTH — halting chain"
    return 1
  fi

  # Generate chain_id if not set
  if [[ -z "$chain_id" ]]; then
    chain_id="chain-$(date -u '+%Y%m%d%H%M%S')-$$"
  fi
  # Sanitize chain_id before using in file paths
  chain_id=$(_sanitize_id "$chain_id")

  # Extract context from result
  local context
  context=$(extract_context "$result_file")

  # Build the chained task
  local target_inbox="$BRIDGE_ROOT/inbox/$dispatch_to"
  mkdir -p "$target_inbox"

  local ts task_filename task_path
  ts=$(date -u '+%Y%m%d%H%M%S')
  task_filename="${ts}-chain-${chain_id##chain-}-d${next_depth}.md"
  task_path="$target_inbox/$task_filename"

  # Get subject from result
  local subject
  subject=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('subject','chained task'))" "$fm_json" 2>/dev/null)
  subject="${subject#Re: }"  # Strip "Re: " prefix if present

  # Get from field (who produced this result)
  local from_agent
  from_agent=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('from','unknown'))" "$fm_json" 2>/dev/null)

  # Sanitize fields for safe YAML output (no injection via crafted values)
  local safe_subject safe_from safe_parent
  safe_subject=$(printf '%s' "$subject" | tr -cd 'a-zA-Z0-9 ._:/-')
  safe_from=$(printf '%s' "$from_agent" | tr -cd 'a-zA-Z0-9._-')
  local raw_parent
  raw_parent=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('task_id',''))" "$fm_json" 2>/dev/null)
  safe_parent=$(_sanitize_id "$raw_parent")

  # Build the task file using printf (not echo) for safe output
  {
    printf '%s\n' "---"
    printf 'from: %s\n' "$safe_from"
    printf 'to: %s\n' "$dispatch_to"
    printf '%s\n' "type: task"
    printf 'subject: "%s"\n' "$safe_subject"
    printf 'chain_id: %s\n' "$chain_id"
    printf 'chain_depth: %s\n' "$next_depth"
    printf 'parent_task_id: %s\n' "$safe_parent"
    printf 'created: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "tier: auto"
    printf '%s\n' "---"
    printf '\n'
  } > "$task_path"

  # Inject context from previous step
  inject_context "$task_path" "$context"

  _chain_log "Dispatched to $dispatch_to: $task_path (chain=$chain_id, depth=$next_depth)"
  return 0
}

# build_chain_task <template_file> <context_block> <chain_id> <depth>
# Builds a new task file from template + context.
# Returns the path to the new task file on stdout.
build_chain_task() {
  local template_file="$1"
  local context_block="$2"
  local chain_id
  chain_id=$(_sanitize_id "$3")
  local depth="$4"

  if [[ ! -f "$template_file" ]]; then
    _chain_log "ERROR: template file not found: $template_file"
    return 1
  fi

  # Depth check
  if (( depth > MAX_CHAIN_DEPTH )); then
    _chain_log "ERROR: depth $depth exceeds max $MAX_CHAIN_DEPTH"
    return 1
  fi

  # Copy template to temp file and inject chain metadata + context
  local tmp_task
  tmp_task=$(mktemp "${TMPDIR:-/tmp}/chain-task-XXXXXX.md")
  cp "$template_file" "$tmp_task"

  # Inject chain metadata into frontmatter
  python3 -c '
import sys, re

task_file = sys.argv[1]
chain_id = sys.argv[2]
depth = sys.argv[3]

content = open(task_file, encoding="utf-8").read()
m = re.match(r"^(---\s*\n)(.*?)(\n---\s*\n?)", content, re.DOTALL)
if m:
    header = m.group(1)
    fm_body = m.group(2)
    footer = m.group(3)
    rest = content[m.end():]
    # Add chain fields if not present
    if "chain_id:" not in fm_body:
        fm_body += f"\nchain_id: {chain_id}"
    if "chain_depth:" not in fm_body:
        fm_body += f"\nchain_depth: {depth}"
    with open(task_file, "w", encoding="utf-8") as f:
        f.write(header + fm_body + footer + rest)
' "$tmp_task" "$chain_id" "$depth"

  # Inject context
  if [[ -n "$context_block" ]]; then
    inject_context "$tmp_task" "$context_block"
  fi

  echo "$tmp_task"
}

# Export all functions
export -f dispatch_next
export -f build_chain_task
export -f _chain_log
export -f _validate_agent
