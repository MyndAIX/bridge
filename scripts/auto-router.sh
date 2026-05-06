#!/bin/bash
# auto-router.sh — MyndAIX Auto-Router
# Watches inbox/dispatch/ and routes tasks to the right agent based on type field
# One inbox to rule them all.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

DISPATCH="$HOME/.myndaix/bridge/inbox/dispatch"
LOG="$HOME/.myndaix/bridge/watchers/auto-router.log"
LOCKDIR="$HOME/.myndaix/bridge/locks/auto-router.lock"
ALERT_WEBHOOK="$(grep DISCORD_WEBHOOK_ALERTS $HOME/.myndaix/discord/.env 2>/dev/null | cut -d= -f2-)"

mkdir -p "$DISPATCH" "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [router] $*" >> "$LOG"; }

alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$ALERT_WEBHOOK" ]; then
    curl -s -H 'Content-Type: application/json' \
      -d "{\"content\": \"📬 **Auto-Router:** $msg\"}" \
      "$ALERT_WEBHOOK" > /dev/null 2>&1
  fi
}

# Prevent double-start (P1: atomic lock with immediate pid write)
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$LOCKDIR/pid" ]; then
    OLD_PID=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Auto-router already running (PID $OLD_PID)"
      exit 0
    fi
    # Stale lock — remove and retry
    rm -rf "$LOCKDIR"
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
      echo "Another router starting — exiting"
      exit 0
    fi
  else
    # Lock dir exists but no pid — race condition, wait and check
    sleep 2
    if [ -f "$LOCKDIR/pid" ]; then
      echo "Another router claimed lock — exiting"
      exit 0
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
  fi
fi
# Write pid immediately after acquiring lock
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

route_file() {
  local file="$1"
  local filename
  filename=$(basename "$file")

  # Extract type from YAML frontmatter
  local task_type
  task_type=$(awk '/^---$/{if(++c==1){next}if(c==2){exit}}c==1{print}' "$file" | grep '^type:' | head -1 | sed 's/^type:[[:space:]]*//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | sed 's/[[:space:]]*$//')

  if [ -z "$task_type" ]; then
    alert "No type field in $filename — cannot route"
    mv "$file" "$HOME/.myndaix/bridge/processed/UNROUTABLE-$filename"
    return
  fi

  # Extract explicit 'to' field from frontmatter (takes priority over type-based routing)
  local explicit_to
  explicit_to=$(awk '/^---$/{if(++c==1){next}if(c==2){exit}}c==1{print}' "$file" | grep '^to:' | head -1 | sed 's/^to:[[:space:]]*//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | sed 's/[[:space:]]*$//')

  local target=""
  local VALID_AGENTS="mini antman kilabz recon lobster harley oracle cli"

  if [ -n "$explicit_to" ]; then
    # Validate the 'to' field is a known agent
    if echo "$VALID_AGENTS" | grep -qw "$explicit_to"; then
      target="$explicit_to"
      log "Routing by 'to' field: $filename → $target"
    else
      alert "Unknown agent '$explicit_to' in 'to' field of $filename — falling back to type routing"
    fi
  fi

  # Fall back to type-based routing if no valid 'to' field
  if [ -z "$target" ]; then
    case "$task_type" in
      task)                          target="mini" ;;
      review)                        target="kilabz" ;;
      research)                      target="recon" ;;
      message|response|result|alert) target="lobster" ;;
      *)
        alert "Unknown type '$task_type' in $filename — cannot route"
        mv "$file" "$HOME/.myndaix/bridge/processed/UNROUTABLE-$filename"
        return
        ;;
    esac
  fi

  local target_inbox="$HOME/.myndaix/bridge/inbox/$target"
  mkdir -p "$target_inbox"

  # Collision-safe: prefix with timestamp if file already exists
  local dest_name="$filename"
  if [ -f "$target_inbox/$filename" ]; then
    dest_name="$(date +%s)-$filename"
  fi

  # Atomic move preferred, guarded copy+delete as fallback (P1: prevent task loss)
  if mv "$file" "$target_inbox/$dest_name" 2>/dev/null; then
    log "Routed: $filename → $target (type: $task_type)"
  elif cp "$file" "$target_inbox/$filename"; then
    rm "$file"
    log "Routed (copy): $filename → $target (type: $task_type)"
  else
    log "ERROR: Failed to route $filename to $target — task preserved in dispatch/"
    alert "Failed to route $filename to $target — file preserved"
    return
  fi
}

log "Auto-router started (PID $$)"

# Process any existing files first
for f in "$DISPATCH"/*.md; do
  [ -f "$f" ] || continue
  route_file "$f"
done

# Watch for new files
fswatch -0 --event Created --event MovedTo --event Renamed "$DISPATCH" | while IFS= read -r -d '' event_path; do
  case "$event_path" in
    *.md) ;;
    *) continue ;;
  esac

  [ -f "$event_path" ] || continue
  sleep 1
  [ -f "$event_path" ] || continue

  route_file "$event_path"
done
