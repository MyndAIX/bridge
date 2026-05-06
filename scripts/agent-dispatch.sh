#!/bin/bash
# agent-dispatch.sh — Agent-to-agent direct task dispatch
# Allows agents to route tasks directly to other agents' inboxes
# with origin-chain tracking and Lobster CC notification.
#
# Usage: agent-dispatch.sh <target-agent> <task-file> <sending-agent> [branch]
#   target-agent : antman | kilabz | mini | mack | recon
#   task-file    : path to the .md task file to forward
#   sending-agent: who is dispatching (mini, antman, etc.)
#   branch       : (optional) branch where work was done
#
# Exit 0 = success, 1 = failure

set -euo pipefail

BRIDGE="$HOME/.myndaix/bridge"
LOG="$BRIDGE/watchers/dispatcher.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [agent-dispatch] $*" >> "$LOG"
}

iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# --- Authorized dispatch routes ---
# Which agents can dispatch to which targets
# Format: "sender:target" pairs
AUTHORIZED_ROUTES=(
  "lobster:mini"
  "lobster:antman"
  "lobster:kilabz"
  "lobster:mack"
  "lobster:recon"
  "lobster:harley"
  "mini:antman"
  "mini:kilabz"
  "mini:mack"
  "antman:kilabz"
  "antman:mini"
  "kilabz:mini"
  "kilabz:antman"
  "mack:antman"
  "mack:kilabz"
  "lobster:smoke"
  "mini:smoke"
  "antman:smoke"
  "mack:smoke"
  "smoke:lobster"
  "smoke:mini"
)

is_authorized() {
  local sender="$1" target="$2"
  local route="${sender}:${target}"
  for r in "${AUTHORIZED_ROUTES[@]}"; do
    [[ "$r" == "$route" ]] && return 0
  done
  return 1
}

# --- Args ---
if [[ $# -lt 3 ]]; then
  echo "Usage: agent-dispatch.sh <target-agent> <task-file> <sending-agent> [branch]"
  exit 1
fi

TARGET="$1"
TASK_FILE="$2"
SENDER="$3"
BRANCH="${4:-}"

if [[ ! -f "$TASK_FILE" ]]; then
  log "ERROR: task file not found: $TASK_FILE"
  exit 1
fi

TARGET_INBOX="$BRIDGE/inbox/$TARGET"
if [[ ! -d "$TARGET_INBOX" ]]; then
  log "ERROR: target inbox not found: $TARGET_INBOX"
  exit 1
fi

# --- Auth check ---
if ! is_authorized "$SENDER" "$TARGET"; then
  log "DENIED: $SENDER is not authorized to dispatch to $TARGET"
  exit 1
fi

# --- Parse existing frontmatter ---
parse_frontmatter_json() {
  ruby -ryaml -rjson -rdate -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
    abort("missing_frontmatter") unless m
    data = YAML.safe_load(m[1], permitted_classes: [Date, Time], aliases: false)
    abort("frontmatter_not_map") unless data.is_a?(Hash)
    puts JSON.generate(data)
  ' "$1"
}

json_get() {
  ruby -rjson -e '
    data = JSON.parse(ARGV[0])
    val = data[ARGV[1]]
    if val.nil?
      puts ""
    elsif val.is_a?(String) || val.is_a?(Numeric) || val == true || val == false
      puts val.to_s
    else
      puts val.to_json
    end
  ' "$1" "$2"
}

# --- Extract body (everything after second ---) ---
extract_body() {
  awk 'BEGIN{c=0} /^---$/{c++; if(c==2){found=1; next}} found{print}' "$1"
}

# --- Build the forwarded task ---
fm_json=""
if ! fm_json=$(parse_frontmatter_json "$TASK_FILE" 2>/dev/null); then
  log "ERROR: cannot parse frontmatter from $TASK_FILE"
  exit 1
fi

# Build chain: append sender to existing chain, or start new one
existing_chain=$(json_get "$fm_json" "chain")
original_from=$(json_get "$fm_json" "from")

if [[ -n "$existing_chain" ]]; then
  # Chain is a JSON array — append sender
  new_chain=$(ruby -rjson -e '
    chain = JSON.parse(ARGV[0])
    chain << ARGV[1] unless chain.include?(ARGV[1])
    puts JSON.generate(chain)
  ' "$existing_chain" "$SENDER")
else
  # Start chain from original sender + current sender
  if [[ -n "$original_from" && "$original_from" != "$SENDER" ]]; then
    new_chain="[\"$original_from\",\"$SENDER\"]"
  else
    new_chain="[\"$SENDER\"]"
  fi
fi

subject=$(json_get "$fm_json" "subject")
task_type=$(json_get "$fm_json" "type")
objective=$(json_get "$fm_json" "objective")
priority=$(json_get "$fm_json" "priority")
tier=$(json_get "$fm_json" "tier")
task_id=$(json_get "$fm_json" "task_id")
repo=$(json_get "$fm_json" "repo")
risk_level=$(json_get "$fm_json" "risk_level")

# Use task type, default to "task" for dispatch_to forwarding
[[ -z "$task_type" || "$task_type" == "result" ]] && task_type="task"
[[ -z "$tier" ]] && tier="auto"

TS=$(date -u '+%Y%m%d%H%M%S')
SLUG=$(echo "$subject" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-40)
[[ -z "$SLUG" ]] && SLUG="forwarded-task"
DEST_FILE="$TARGET_INBOX/${TS}-${SENDER}-${task_type}-${SLUG}.md"

BODY=$(extract_body "$TASK_FILE")

# ── Workflow context injection (Upgrade 7 Part A — Symphony) ──
# Looks up per-project workflow from factory/workflows/ and injects
# the section relevant to the target agent's role into the task body.
# Additive only — existing body is never modified or replaced.
# TRUST BOUNDARY: workflow files are an instruction source — anyone with write
# access to factory/workflows/ can inject prompts into agent contexts.
WORKFLOWS_DIR="$HOME/.myndaix/factory/workflows"

resolve_agent_role() {
  case "$1" in
    mini|mack|antman) echo "Build agents" ;;
    kilabz)           echo "Review agents" ;;
    oracle)           echo "Architecture review" ;;
    recon)            echo "Research" ;;
    harley)           echo "Creative" ;;
    *)                echo "" ;;
  esac
}

find_workflow_file() {
  local task_repo="$1"
  [[ -z "$task_repo" || ! -d "$WORKFLOWS_DIR" ]] && return 0
  local expanded_repo="${task_repo/#\~/$HOME}"
  local best_file="" best_len=0
  for wf in "$WORKFLOWS_DIR"/*.md; do
    [[ ! -f "$wf" ]] && continue
    local wf_repo
    wf_repo=$(awk '/^---$/{c++; next} c==1 && /^repo:/{sub(/^repo:[[:space:]]*/, ""); print; exit}' "$wf")
    [[ -z "$wf_repo" ]] && continue
    local expanded_wf="${wf_repo/#\~/$HOME}"
    local match_len=0
    if [[ "$expanded_repo" == "$expanded_wf" ]]; then
      match_len=${#expanded_wf}
    else
      local proj_name
      proj_name=$(basename "$expanded_wf")
      if [[ "$expanded_repo" == *"/$proj_name"* || "$expanded_repo" == *"$proj_name"* ]]; then
        match_len=${#expanded_wf}
      fi
    fi
    if (( match_len > best_len )) || { (( match_len == best_len )) && (( match_len > 0 )) && [[ "$wf" < "$best_file" ]]; }; then
      best_file="$wf"
      best_len=$match_len
    fi
  done
  [[ -n "$best_file" ]] && echo "$best_file"
  return 0
}

extract_workflow_section() {
  local wf_file="$1" role="$2"
  [[ -z "$wf_file" || -z "$role" ]] && return 0
  awk -v role="$role" '
    /^### /{
      prefix = "### " role
      if (substr($0, 1, length(prefix)) == prefix) {
        rest = substr($0, length(prefix) + 1)
        if (rest == "" || substr(rest, 1, 2) == " (") { found=1; next }
      }
      if (found) { exit }
    }
    found { print }
  ' "$wf_file"
}

_wf_file=$(find_workflow_file "$repo")
if [[ -n "$_wf_file" ]]; then
  _wf_role=$(resolve_agent_role "$TARGET")
  _wf_section=""
  if [[ -n "$_wf_role" ]]; then
    _wf_section=$(extract_workflow_section "$_wf_file" "$_wf_role")
  fi
  _wf_counsel=$(extract_workflow_section "$_wf_file" "Outside counsel integration")
  _wf_project=$(basename "${_wf_file%.md}")
  if [[ -n "$_wf_section" || -n "$_wf_counsel" ]]; then
    _wf_block=$'\n\n## Workflow Context ('"$_wf_project"')\n'
    if [[ -n "$_wf_section" ]]; then
      _wf_block+=$'\n### '"$_wf_role"$'\n'"$_wf_section"
    fi
    if [[ -n "$_wf_counsel" ]]; then
      _wf_block+=$'\n### Outside counsel integration\n'"$_wf_counsel"
    fi
    BODY="${BODY}${_wf_block}"
    log "WORKFLOW: injected $_wf_project/$_wf_role context for $TARGET"
  fi
fi

{
  echo "---"
  echo "from: $SENDER"
  echo "to: $TARGET"
  echo "type: $task_type"
  echo "subject: \"$subject\""
  [[ -n "$objective" ]] && echo "objective: \"$objective\""
  [[ -n "$priority" ]] && echo "priority: $priority"
  echo "tier: $tier"
  [[ -n "$task_id" ]] && echo "task_id: $task_id"
  [[ -n "$repo" ]] && echo "repo: \"$repo\""
  [[ -n "$BRANCH" ]] && echo "branch: \"$BRANCH\""
  [[ -n "$risk_level" ]] && echo "risk_level: $risk_level"
  echo "chain: $new_chain"
  echo "dispatched_by: $SENDER"
  echo "created: $(iso_now)"
  echo "---"
  echo
  echo "$BODY"
} > "$DEST_FILE"

# Verify write
if [[ ! -s "$DEST_FILE" ]]; then
  log "ERROR: failed to write dispatch file: $DEST_FILE"
  exit 1
fi


# -- SQLite task queue (Upgrade 5 — parallel run with file-based) --
# Failure here is non-fatal — file dispatch already succeeded.
_TQ_DB="$HOME/.myndaix/memory.db"
if [[ -f "$_TQ_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
  _tq_id="TASK-$(date +%s)-$(openssl rand -hex 4 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(4))')"
  _tq_pri="${priority:-5}"
  case "$_tq_pri" in
    P0|p0) _tq_pri=1 ;; P1|p1) _tq_pri=2 ;; P2|p2) _tq_pri=3 ;; P3|p3) _tq_pri=5 ;;
    [1-9]) ;; *) _tq_pri=5 ;;
  esac
  _tq_obj=$(printf '%s' "${objective:-$subject}" | sed "s/'/''/g")
  _tq_body=$(printf '%s' "$BODY" | sed "s/'/''/g" | head -c 8000)
  _tq_branch=$(printf '%s' "$BRANCH" | sed "s/'/''/g")
  _tq_dest=$(printf '%s' "$DEST_FILE" | sed "s/'/''/g")
  _tq_type=$(printf '%s' "$task_type" | sed "s/'/''/g")
  if sqlite3 "$_TQ_DB" \
    "INSERT INTO tasks (id, type, agent, priority, status, objective, body, branch, dispatched_by, inbox_file)
     VALUES ('$_tq_id', '$_tq_type', '$TARGET', $_tq_pri, 'queued', '$_tq_obj', '$_tq_body', '$_tq_branch', '$SENDER', '$_tq_dest')" 2>/dev/null; then
    log "SQLite-queued: $_tq_id (target=$TARGET, priority=$_tq_pri)"
  else
    log "WARN: SQLite queue insert failed for $_tq_id — file path still succeeded"
  fi
fi

log "DISPATCHED: $SENDER -> $TARGET: $(basename "$DEST_FILE") (chain: $new_chain)"

# ── Telemetry: log dispatched task ──
_telemetry_dir="$HOME/.myndaix/telemetry"
mkdir -p "$_telemetry_dir"
_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"task_id":"%s","agent":"%s","type":"%s","status":"dispatched","model":"n/a","tokens_in":0,"tokens_out":0,"error":"null","timestamp":"%s"}\n' \
  "${task_id:-$(basename "$DEST_FILE" .md)}" "$TARGET" "${task_type:-task}" "$_ts" \
  >> "$_telemetry_dir/tasks.jsonl"

# --- CC notification to Lobster ---
# Only send CC if target is not lobster (avoid duplicate)
if [[ "$TARGET" != "lobster" ]]; then
  CC_FILE="$BRIDGE/inbox/lobster/${TS}-cc-${SENDER}-to-${TARGET}.md"
  {
    echo "---"
    echo "from: $SENDER"
    echo "to: lobster"
    echo "type: message"
    echo "subject: \"[CC] $SENDER dispatched ${task_type} to $TARGET: $subject\""
    echo "chain: $new_chain"
    echo "created: $(iso_now)"
    echo "---"
    echo
    echo "## Agent-to-Agent Dispatch Notification"
    echo
    echo "**From:** $SENDER"
    echo "**To:** $TARGET"
    echo "**Type:** $task_type"
    echo "**Subject:** $subject"
    [[ -n "$task_id" ]] && echo "**Task ID:** $task_id"
    [[ -n "$BRANCH" ]] && echo "**Branch:** $BRANCH"
    echo "**Chain:** $new_chain"
    echo
    echo "Task file: $(basename "$DEST_FILE")"
  } > "$CC_FILE"
  log "CC sent to lobster: $(basename "$CC_FILE")"
fi

echo "$DEST_FILE"
exit 0
