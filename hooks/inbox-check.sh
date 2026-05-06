#!/bin/bash
# Inbox check hook for Claude Code
# SessionStart: dump all pending message contents
# PreToolUse: dump new message contents once (marker-based debounce)
set -euo pipefail

INBOX="$HOME/.myndaix/bridge/inbox/mack"
MARKER="$HOME/.myndaix/bridge/state/inbox-notified.marker"
MODE="${1:-pretool}"

mkdir -p "$HOME/.myndaix/bridge/state"

# Pull new messages from Mini before checking local inbox
"$HOME/.myndaix/bridge/scripts/bridge-pull.sh" 2>/dev/null || true

# Get .md files as array
get_all_messages() {
  find "$INBOX" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort
}

get_new_messages() {
  find "$INBOX" -maxdepth 1 -name "*.md" -type f -newer "$MARKER" 2>/dev/null | sort
}

# Dump message contents (takes file list on stdin)
dump_messages() {
  while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    local fname
    fname=$(basename "$filepath")
    echo "--- MESSAGE: $fname ---"
    cat "$filepath"
    echo ""
    echo "--- END ---"
    echo ""
  done
}

# --- SessionStart mode: dump everything ---
if [[ "$MODE" == "session" ]]; then
  FILES=$(get_all_messages)
  if [[ -n "$FILES" ]]; then
    COUNT=$(echo "$FILES" | wc -l | tr -d ' ')
    echo "INBOX: ${COUNT} message(s) in ~/.myndaix/bridge/inbox/mack/"
    echo ""
    echo "$FILES" | dump_messages
    echo "Review these messages and discuss with Jefe before starting other work."
  fi
  touch "$MARKER"
  exit 0
fi

# --- PreToolUse mode: dump only new messages since marker ---
if [[ "$MODE" == "pretool" ]]; then
  if [[ ! -f "$MARKER" ]]; then
    touch "$MARKER"
    exit 0
  fi

  NEW_FILES=$(get_new_messages)

  if [[ -z "$NEW_FILES" ]]; then
    exit 0
  fi

  NEW_COUNT=$(echo "$NEW_FILES" | wc -l | tr -d ' ')

  # Build the full content to inject
  CONTENT=$(echo "$NEW_FILES" | dump_messages)

  # Touch marker before output so we don't re-notify
  touch "$MARKER"

  # Escape content for JSON
  ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": ${ESCAPED}
  }
}
EOF
  exit 0
fi
