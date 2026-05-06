#!/bin/bash
# pre-dispatch-gate.sh — Hard gate: blocks dispatch/deploy if process rules violated
# PreToolUse hook on Bash commands
# Checks: (1) uncommitted changes before dispatch, (2) systems-check before deploy
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Source shared validation library (no SHA256 check in hooks — fires every command)
# P1 fix: hardcode BRIDGE_DIR — never trust env for source paths
BRIDGE_DIR="$HOME/.myndaix/bridge"
export BRIDGE_DIR
# P1 fix: fail closed if validation library can't load
if [[ ! -f "$BRIDGE_DIR/watchers/lib/validate.sh" ]]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","reason":"BLOCKED: validate.sh not found — cannot load validation library"}}'
  exit 0
fi
source "$BRIDGE_DIR/watchers/lib/validate.sh" || {
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","reason":"BLOCKED: validate.sh failed to load"}}'
  exit 0
}

# --- Config ---
# Deploy targets — hostnames/IPs that require systems-check before SCP
DEPLOY_TARGETS_FILE="$HOME/.myndaix/bridge/state/deploy-targets.conf"
# Default targets if config doesn't exist
DEFAULT_TARGETS="100.112|jefe@|${MINI_HOSTNAME:-mini}"
MARKER_MAX_AGE_MIN=60

# Read the command from hook input (stdin)
# P1 fix: fail closed on parse error — deny if we can't read the command
# Uses python3 -c so script is a CLI arg and stdin stays available for the pipe
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    cmd=d.get("tool_input",{}).get("command","")
    if not isinstance(cmd,str): sys.exit(1)
    print(cmd)
except Exception: sys.exit(1)
')
PARSE_OK=$?

if [[ "$PARSE_OK" -ne 0 ]]; then
  if declare -F fail_closed_deny >/dev/null 2>&1; then
    fail_closed_deny "pre-dispatch-gate failed to parse hook input. Failing closed for safety."
  else
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","reason":"BLOCKED: parse failure"}}'
  fi
  exit 0
fi

# --- Helpers ---
is_dispatch_command() {
  # Specific dispatch patterns — not generic scp or inbox mentions
  # Match: dispatch_task/dispatch_review/dispatch_research calls
  echo "$COMMAND" | grep -qE 'dispatch_(task|review|research)\b' && return 0
  # Match: SCP to known agent inbox paths
  echo "$COMMAND" | grep -qE 'scp.*\.myndaix/bridge/inbox/' && return 0
  # Match: writing .md files to inbox directories (dispatch files)
  echo "$COMMAND" | grep -qE '(cat|tee|cp|mv).*inbox/[a-z]+/.*\.md' && return 0
  return 1
}

is_deploy_command() {
  # P2 fix: use fixed-string matching per target to avoid regex injection
  # P3 fix: filter empty/whitespace-only lines from conf
  local target_list
  if [[ -f "$DEPLOY_TARGETS_FILE" ]]; then
    target_list=$(grep -v '^#' "$DEPLOY_TARGETS_FILE" 2>/dev/null | grep -v '^[[:space:]]*$')
  else
    target_list="$DEFAULT_TARGETS"
  fi

  # Only check scp commands
  echo "$COMMAND" | grep -q 'scp' || return 1

  # Check each target with fixed-string match (no regex interpretation)
  # P1 fix: use newline delimiter (not NUL) so each target is checked individually
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    echo "$COMMAND" | grep -qF "$target" && return 0
  done <<< "$(printf '%s\n' "$target_list" | tr '|' '\n')"
  return 1
}

# --- Fast exit for non-dispatch/deploy commands ---
if ! is_dispatch_command && ! is_deploy_command; then
  exit 0
fi

# --- Check 1: Uncommitted changes before dispatch ---
if is_dispatch_command; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    DIRTY=$(git status --porcelain 2>/dev/null)
    if [[ -n "$DIRTY" ]]; then
      DIRTY_COUNT=$(echo "$DIRTY" | wc -l | tr -d ' ')
      if declare -F fail_closed_deny >/dev/null 2>&1; then
        fail_closed_deny "${DIRTY_COUNT} uncommitted file(s) detected. Commit and push before dispatching. Run: git add -A && git commit -m 'message' && git push"
      else
        echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"reason\":\"BLOCKED: ${DIRTY_COUNT} uncommitted files\"}}"
      fi
      exit 0
    fi
  fi
fi

# --- Check 2: Systems-check before SCP to deploy targets ---
if is_deploy_command; then
  MARKER="$HOME/.myndaix/bridge/state/systems-check-ran.marker"
  if [[ ! -f "$MARKER" ]] || [[ $(find "$MARKER" -mmin +"$MARKER_MAX_AGE_MIN" 2>/dev/null) ]]; then
    if declare -F fail_closed_deny >/dev/null 2>&1; then
      fail_closed_deny "systems-check.sh has not been run in the last ${MARKER_MAX_AGE_MIN} minutes. Run: ~/.myndaix/bridge/scripts/systems-check.sh <files> — then retry."
    else
      echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"reason\":\"BLOCKED: systems-check not run\"}}"
    fi
    exit 0
  fi
fi

# All checks passed — allow
exit 0
