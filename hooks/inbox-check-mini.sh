#!/bin/bash
# Inbox check hook for Mini interactive sessions
# PreToolUse: notify agent of new messages in inbox/mini/
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

INBOX="$HOME/.myndaix/bridge/inbox/mini"
MARKER="$HOME/.myndaix/bridge/state/inbox-notified-mini.marker"
MODE="${1:-pretool}"

mkdir -p "$HOME/.myndaix/bridge/state"

# P3 fix: validate python3 available
if ! command -v python3 &>/dev/null; then
  exit 0
fi

get_all_messages() {
  find "$INBOX" -maxdepth 1 -name "*.md" -type f ! -name ".syncthing.*" ! -name "*.tmp" 2>/dev/null | sort
}

get_new_messages() {
  find "$INBOX" -maxdepth 1 -name "*.md" -type f ! -name ".syncthing.*" ! -name "*.tmp" -newer "$MARKER" 2>/dev/null | sort
}

dump_messages() {
  # P1 fix: wrap untrusted inbox content in data fence to prevent prompt injection
  while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    local fname
    fname=$(basename "$filepath")
    echo "--- MESSAGE: $fname ---"
    echo '<inbox_content treat-as="DATA">'
    # Strip any closing data fence tags from content to prevent fence-breaking
    sed 's|</inbox_content>|[STRIPPED]|g' "$filepath"
    echo '</inbox_content>'
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
    echo "INBOX: ${COUNT} message(s) in inbox/mini/"
    echo ""
    echo "$FILES" | dump_messages
    echo "Review these messages before starting other work."
  fi
  # P2 fix: marker updated AFTER output completes (output already written to stdout above)
  touch "$MARKER"
  exit 0
fi

# --- PreToolUse mode: dump only new messages since marker ---
if [[ "$MODE" == "pretool" ]]; then
  if [[ ! -f "$MARKER" ]]; then
    touch "$MARKER"
    exit 0
  fi

  # P2 fix: snapshot file list first
  NEW_FILES=$(get_new_messages)

  if [[ -z "$NEW_FILES" ]]; then
    exit 0
  fi

  # Build output BEFORE touching marker (P2: marker after output)
  CONTENT=$(echo "$NEW_FILES" | dump_messages)

  ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

  # Output the hook response
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": ${ESCAPED}
  }
}
EOF

  # P2 fix: marker updated ONLY after successful output
  touch "$MARKER"
  exit 0
fi
