#!/usr/bin/env bash
# inbox-watcher.sh — watches bridge inbox, sends Discord notification + wakes OpenClaw
set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"

export BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"

INBOX_DIR="$BRIDGE_DIR/inbox/lobster"
SEEN_FILE="$BRIDGE_DIR/watchers/.seen"
LOG_FILE="$BRIDGE_DIR/watchers/watcher.log"

# Discord notifications: source webhook from ~/.myndaix/.secrets if present.
# When DISCORD_WEBHOOK is empty, send_discord() becomes a no-op (fail-closed).
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"

mkdir -p "$(dirname "$SEEN_FILE")"
touch "$SEEN_FILE"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

parse_frontmatter() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    /^---$/ { if (in_fm) exit; in_fm=1; next }
    in_fm && $0 ~ "^"key":" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^["'"'"'"]|["'"'"'"]$/, ""); print; exit }
  ' "$file"
}

# Extract body — truncate entirely within awk to avoid SIGPIPE from head
extract_body() {
  local file="$1"
  awk '
    /^---$/ { count++; if (count==2) { printing=1; next } }
    printing { print; lines++; if (lines>=40) exit }
  ' "$file"
}

send_discord() {
  local message="$1"
  if [[ -z "$DISCORD_WEBHOOK" ]]; then
    log "DISCORD_WEBHOOK not set; skipping Discord notification"
    return 0
  fi
  message="${message:0:1900}"
  curl -s --max-time 10 -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"content\": $(printf '%s' "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" > /dev/null 2>&1 || true
}

notify() {
  local file="$1"
  local basename
  basename="$(basename "$file")"

  if grep -qF "$basename" "$SEEN_FILE" 2>/dev/null; then
    return
  fi

  local from subject body
  from="$(parse_frontmatter "$file" "from")"
  subject="$(parse_frontmatter "$file" "subject")"
  body="$(extract_body "$file")"

  [ -z "$from" ] && from="unknown"
  [ -z "$subject" ] && subject="$basename"

  echo "$basename" >> "$SEEN_FILE"

  log "NEW: from=$from subject=$subject file=$basename"

  # Auto-advance conversation threads before notifying
  local conv_orch="$HOME/.myndaix/bridge/scripts/conversation-orchestrator.sh"
  if [[ -x "$conv_orch" && "$basename" == *-result.md ]]; then
    local orch_result
    orch_result=$(bash "$conv_orch" "$file" 2>>"$LOG_FILE") || true
    if [[ "$orch_result" == ADVANCED:* ]]; then
      log "THREAD: auto-advanced ${basename} → ${orch_result}"
      # Don't wake Lobster for intermediate rounds — orchestrator handles it
      return
    elif [[ "$orch_result" == "COMPLETE" ]]; then
      log "THREAD: ${basename} completed final round"
      # Fall through to wake Lobster for the final summary
    fi
  fi

  send_discord "📬 **Bridge message**
**From:** ${from}
**Subject:** ${subject}

${body}

---
*File: ${basename}*"
  log "DISCORD: sent notification for $basename"

  if /opt/homebrew/bin/openclaw system event --mode now --text "[Bridge] New message from ${from}: ${subject}" 2>>"$LOG_FILE"; then
    log "OPENCLAW: triggered wake for $basename"
  else
    log "OPENCLAW: trigger FAILED for $basename (exit $?)"
  fi
}

process_existing() {
  for f in "$INBOX_DIR"/*.md; do
    [ -f "$f" ] || continue
    notify "$f"
  done
}

log "=== Inbox watcher started ==="
log "Watching: $INBOX_DIR"

process_existing

/opt/homebrew/bin/fswatch -0 "$INBOX_DIR" | while IFS= read -r -d '' event; do
  if [[ "$event" == *.md ]] && [ -f "$event" ]; then
    sleep 0.5
    notify "$event"
  fi
done

# If we reach here, fswatch died — exit non-zero so self-heal restarts us
log "FATAL: fswatch event loop exited — inbox-watcher is dead"
exit 1
