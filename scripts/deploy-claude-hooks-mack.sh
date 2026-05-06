#!/bin/bash
# deploy-claude-hooks-mack.sh — Deploy Claude Code observability hooks to Mack (MacBook)
#
# Usage: ./deploy-claude-hooks-mack.sh [macbook-host]
#   macbook-host: SSH hostname for MacBook (default: macbook or MACK_HOST env var)
#
# Prerequisites:
#   - SSH key access to MacBook
#   - Claude Code installed on MacBook
#   - ~/.myndaix/ structure exists on MacBook

set -euo pipefail

export HOME="${HOME:-/Users/$(whoami)}"
export BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"

MACBOOK="${1:-${MACK_HOST:-macbook}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Deploying Claude Code observability hooks to $MACBOOK"

# 1. Create hooks directory on MacBook
echo "--- Creating hooks directory on MacBook..."
ssh "$MACBOOK" "mkdir -p ~/.myndaix/bridge/scripts/hooks/ ~/.myndaix/bridge/state/"

# 2. Copy hook scripts
echo "--- Copying hook scripts..."
scp "$SCRIPT_DIR/hooks/"*.sh "$MACBOOK:~/.myndaix/bridge/scripts/hooks/"

# 3. Make scripts executable
echo "--- Setting script permissions..."
ssh "$MACBOOK" "chmod +x ~/.myndaix/bridge/scripts/hooks/*.sh"

# 4. Backup existing Claude settings
echo "--- Backing up existing Claude settings..."
ssh "$MACBOOK" "cp ~/.claude/settings.json ~/.claude/settings.json.backup 2>/dev/null || echo 'No existing settings.json to backup'"

# 5. Update Claude settings.json on MacBook
echo "--- Updating Claude settings.json..."
ssh "$MACBOOK" 'cat > /tmp/update_claude_hooks.sh << '"'"'EOF'"'"'
#!/bin/bash
# Script to update Claude settings.json with observability hooks

SETTINGS_FILE="$HOME/.claude/settings.json"

# Check if settings.json exists
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Creating new settings.json..."
    cat > "$SETTINGS_FILE" << "SETTINGS_EOF"
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash(*)",
      "Glob",
      "Grep",
      "WebSearch",
      "WebFetch"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$BRIDGE_DIR/scripts/hooks/pre_tool_use.sh",
            "async": true
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$BRIDGE_DIR/scripts/hooks/post_tool_use.sh",
            "async": true
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$BRIDGE_DIR/scripts/hooks/subagent_start.sh",
            "async": true
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$BRIDGE_DIR/scripts/hooks/subagent_stop.sh",
            "async": true
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
else
    echo "Claude settings.json exists. Manual merge required for existing hooks."
    echo "Please manually add the observability hooks to your existing settings.json"
fi
EOF

chmod +x /tmp/update_claude_hooks.sh
/tmp/update_claude_hooks.sh
rm /tmp/update_claude_hooks.sh'

# 6. Verify deployment
echo "--- Verifying deployment..."
if ssh "$MACBOOK" "test -f ~/.myndaix/bridge/scripts/hooks/log_event.sh"; then
    echo "✅ Hook scripts deployed successfully"
else
    echo "❌ Failed to deploy hook scripts"
    exit 1
fi

if ssh "$MACBOOK" "test -f ~/.claude/settings.json"; then
    echo "✅ Claude settings.json exists"
else
    echo "❌ Claude settings.json not found"
    exit 1
fi

echo ""
echo "🎉 SUCCESS: Claude Code observability hooks deployed to $MACBOOK"
echo ""
echo "Next steps:"
echo "1. Events will be logged to: ~/.myndaix/bridge/state/events.jsonl"
echo "2. Test by running a Claude Code session on the MacBook"
echo "3. Check events with: ssh $MACBOOK 'tail -f ~/.myndaix/bridge/state/events.jsonl'"
echo ""
echo "If you had existing hooks in settings.json, please manually merge them."