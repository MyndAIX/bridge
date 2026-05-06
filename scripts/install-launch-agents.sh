#!/usr/bin/env bash
# install-launch-agents.sh — render launchd/templates/*.template into
# ~/Library/LaunchAgents/, substituting __BRIDGE_DIR__, __HOME__, __USER__
# placeholders with absolute paths from the current shell's environment.
#
# Idempotent: re-runs overwrite the rendered plists in-place. The user's
# existing LaunchAgents are validated with `plutil -lint` after substitution
# — if a plist would be malformed, the install aborts before writing.
#
# Usage:
#   bash scripts/install-launch-agents.sh           # render + install
#   bash scripts/install-launch-agents.sh --dry-run # show what would render

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"
export BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
USER="${USER:-$(whoami)}"

# Source ~/.myndaix/.secrets so __PERPLEXITY_API_KEY__, __GEMINI_API_KEY__,
# and any other secret placeholders in templates can be substituted from env.
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

TEMPLATE_DIR="$BRIDGE_DIR/launchd/templates"
TARGET_DIR="$HOME/Library/LaunchAgents"

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  echo "✗ Template dir not found: $TEMPLATE_DIR"
  echo "  Is BRIDGE_DIR set correctly? (current: $BRIDGE_DIR)"
  exit 1
fi

mkdir -p "$TARGET_DIR"
INSTALLED=0
SKIPPED=0

for tpl in "$TEMPLATE_DIR"/*.template; do
  [[ -f "$tpl" ]] || continue
  base=$(basename "$tpl" .template)
  out="$TARGET_DIR/$base"

  rendered=$(sed \
    -e "s|__BRIDGE_DIR__|$BRIDGE_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|>__USER__<|>$USER<|g" \
    -e "s|__PERPLEXITY_API_KEY__|${PERPLEXITY_API_KEY:-}|g" \
    -e "s|__GEMINI_API_KEY__|${GEMINI_API_KEY:-}|g" \
    -e "s|__ELEVENLABS_API_KEY__|${ELEVENLABS_API_KEY:-}|g" \
    "$tpl")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "----- $out -----"
    echo "$rendered"
    echo
    continue
  fi

  # Validate via plutil before writing. macOS-only but acceptable since
  # LaunchAgents are macOS-only anyway.
  tmpfile=$(mktemp -t plist-XXXX.plist)
  echo "$rendered" > "$tmpfile"
  if ! plutil -lint "$tmpfile" >/dev/null 2>&1; then
    echo "✗ Template renders to invalid plist: $tpl"
    plutil -lint "$tmpfile"
    exit 1
  fi
  mv "$tmpfile" "$out"
  chmod 644 "$out"
  INSTALLED=$((INSTALLED+1))
  echo "✓ $out"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(dry run — nothing written)"
  exit 0
fi

echo
echo "✓ Installed $INSTALLED LaunchAgents to $TARGET_DIR"
echo
echo "Next: bootstrap them into launchd"
echo "  launchctl bootstrap gui/\$(id -u) $TARGET_DIR/ai.myndaix.*.plist"
echo "  launchctl bootstrap gui/\$(id -u) $TARGET_DIR/com.myndaix.*.plist"
echo
echo "Verify:"
echo "  launchctl list | grep myndaix"
