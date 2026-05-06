#!/bin/bash
set -euo pipefail

export HOME="${HOME:-/Users/$(whoami)}"
export BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"

# deploy-mack.sh — Deploy Mack watcher to MacBook
#
# Usage: ./deploy-mack.sh [macbook-host]
#   macbook-host: SSH hostname for MacBook (default: macbook or MACK_HOST env var)
#
# Prerequisites:
#   - SSH key access to MacBook (ssh macbook works)
#   - Claude Code installed on MacBook
#   - ~/.myndaix/ structure exists on MacBook (Syncthing handles this)
#   - ~/.myndaix/.secrets exists on MacBook with API keys

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACBOOK="${1:-${MACK_HOST:-macbook}}"

REMOTE_WATCHERS="$BRIDGE_DIR/watchers"
REMOTE_PROFILES="$HOME/.myndaix/agent-profiles"
REMOTE_LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_LABEL="ai.myndaix.mack-watcher"

echo "==> Deploying Mack watcher to $MACBOOK"

# 1. Copy watcher scripts
echo "--- Copying watcher scripts..."
ssh "$MACBOOK" "mkdir -p '$REMOTE_WATCHERS' '$REMOTE_PROFILES'"
scp "$SCRIPT_DIR/mack-watcher.sh" "$MACBOOK:$REMOTE_WATCHERS/mack-watcher.sh"
scp "$SCRIPT_DIR/mack-runner.sh" "$MACBOOK:$REMOTE_WATCHERS/mack-runner.sh"

# 2. Copy agent profile if not already synced
echo "--- Copying agent profile..."
scp "$SCRIPT_DIR/../../../agent-profiles/mack-autonomous.json" "$MACBOOK:$REMOTE_PROFILES/mack-autonomous.json" 2>/dev/null || \
  scp "$HOME/.myndaix/agent-profiles/mack-autonomous.json" "$MACBOOK:$REMOTE_PROFILES/mack-autonomous.json"

# 3. Make scripts executable
echo "--- Setting permissions..."
ssh "$MACBOOK" "chmod +x '$REMOTE_WATCHERS/mack-watcher.sh' '$REMOTE_WATCHERS/mack-runner.sh'"

# 4. Install LaunchAgent plist
echo "--- Installing LaunchAgent plist..."
scp "$SCRIPT_DIR/ai.myndaix.mack-watcher.plist" "$MACBOOK:$REMOTE_LAUNCH_AGENTS/$PLIST_LABEL.plist"

# 5. Unload existing (ignore errors if not loaded)
echo "--- Unloading existing LaunchAgent (if any)..."
ssh "$MACBOOK" "launchctl unload '$REMOTE_LAUNCH_AGENTS/$PLIST_LABEL.plist' 2>/dev/null || true"

# 6. Load the LaunchAgent
echo "--- Loading LaunchAgent..."
ssh "$MACBOOK" "launchctl load '$REMOTE_LAUNCH_AGENTS/$PLIST_LABEL.plist'"

# 7. Create inbox directory on MacBook
echo "--- Ensuring inbox directory exists..."
ssh "$MACBOOK" "mkdir -p $BRIDGE_DIR/inbox/mack $BRIDGE_DIR/inbox/lobster $BRIDGE_DIR/processed $BRIDGE_DIR/locks $BRIDGE_DIR/state"

# 8. Verify
echo "--- Verifying..."
if ssh "$MACBOOK" "launchctl list | grep -q '$PLIST_LABEL'"; then
  echo "==> SUCCESS: $PLIST_LABEL is loaded and running on $MACBOOK"
else
  echo "==> WARNING: $PLIST_LABEL may not be loaded. Check with: ssh $MACBOOK launchctl list | grep mack"
fi

echo ""
echo "Done. Mack watcher is deployed to $MACBOOK."
echo "Logs: ssh $MACBOOK 'tail -f /tmp/mack-watcher-stdout.log'"
echo "Test: drop a .md task file into ~/.myndaix/bridge/inbox/mack/"
