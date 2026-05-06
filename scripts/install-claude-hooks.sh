#!/usr/bin/env bash
# install-claude-hooks.sh — register MyndAIX safety hooks in ~/.claude/settings.json
#
# Without this, agents that invoke `claude` from arbitrary working dirs (e.g.
# inside per-task git worktrees) run with no safety rails — they can `git push
# --force` to main, `rm -rf` your repo, or execute syntactically broken bash.
#
# This script merges three PreToolUse hooks into the user-global settings:
#   * branch-guard.sh       blocks force-push to main/master
#   * destructive-blocker.sh blocks rm -rf, DROP TABLE, git reset --hard origin
#   * syntax-check.sh        runs bash -n on bash -c payloads before exec
#
# Idempotent: re-runs replace any existing matcher=="Bash" PreToolUse block.
# A timestamped backup is created at ~/.claude/settings.json.bak.<ts> first.
#
# Project-local alternative: this repo also ships .claude/settings.json with
# the same hooks scoped via ${CLAUDE_PROJECT_DIR}, active when `claude` is
# run from inside the repo. Use the user-global form below when watchers
# spawn `claude` from worktrees outside the bridge dir.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"
export BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"

command -v jq >/dev/null || { echo "✗ jq not found in PATH (brew install jq)"; exit 1; }

settings="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$settings")"
[[ -f "$settings" ]] || echo '{}' > "$settings"

# Backup before mutating
cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"

# Verify the three hook scripts exist and are executable
for h in branch-guard destructive-blocker syntax-check; do
  path="$BRIDGE_DIR/hooks/${h}.sh"
  if [[ ! -f "$path" ]]; then
    echo "✗ $path not found — is BRIDGE_DIR set correctly? (current: $BRIDGE_DIR)" >&2
    exit 1
  fi
  if [[ ! -x "$path" ]]; then
    echo "  chmod +x $path"
    chmod +x "$path"
  fi
done

# Build the hook block with absolute paths.
# (Claude Code does NOT expand env vars inside `command` strings in user-global
# settings — only ${CLAUDE_PROJECT_DIR} works in project-local files.)
hook_block=$(jq -n --arg b "$BRIDGE_DIR" '{
  matcher: "Bash",
  hooks: [
    { type: "command", command: ($b + "/hooks/branch-guard.sh") },
    { type: "command", command: ($b + "/hooks/destructive-blocker.sh") },
    { type: "command", command: ($b + "/hooks/syntax-check.sh") }
  ]
}')

# Merge: replace any existing matcher == "Bash" PreToolUse entry, otherwise append.
tmp=$(mktemp)
jq --argjson block "$hook_block" '
  .hooks //= {}
  | .hooks.PreToolUse //= []
  | .hooks.PreToolUse |= ( map(select(.matcher != "Bash")) + [$block] )
' "$settings" > "$tmp" && mv "$tmp" "$settings"

# Validate the resulting JSON
jq -e . "$settings" >/dev/null || {
  echo "✗ settings.json is invalid JSON after merge — restore from .bak"; exit 1
}

count=$(jq '[.hooks.PreToolUse[]?|select(.matcher=="Bash")|.hooks[]] | length' "$settings")
echo "✓ Registered $count PreToolUse hooks in $settings"
echo "  Backup: $(ls -t "$settings".bak.* 2>/dev/null | head -1)"
echo "  Verify: jq '.hooks.PreToolUse[]|select(.matcher==\"Bash\")' $settings"
echo
echo "Negative test (must be blocked):"
echo "  claude --dangerously-skip-permissions --print 'run: rm -rf \$HOME/test-target' 2>&1 | grep -q 'destructive\\|blocked'"
