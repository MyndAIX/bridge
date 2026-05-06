#!/bin/bash
# new-script-warning.sh — Advisory: warns when new .sh files lack test or DESIGN.md
# PostToolUse hook on Write tool
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Source shared validation library
# P1 fix: hardcode BRIDGE_DIR — never trust env for source paths
BRIDGE_DIR="$HOME/.myndaix/bridge"
export BRIDGE_DIR
# P2 fix: warn (not block) if validation library fails — this is an advisory hook
if [[ ! -f "$BRIDGE_DIR/watchers/lib/validate.sh" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [new-script-warning] WARNING: validate.sh not found, running without shared validation" >&2
fi
source "$BRIDGE_DIR/watchers/lib/validate.sh" 2>/dev/null || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [new-script-warning] WARNING: validate.sh failed to load" >&2
}

# Read the hook input from stdin
# Note: pass via env var, not pipe — heredoc and pipe conflict for stdin
INPUT=$(cat)
FILE_PATH=$(HOOK_INPUT="$INPUT" python3 << 'PYEOF'
import json, sys, os
try:
    d = json.loads(os.environ['HOOK_INPUT'])
    fp = d.get('tool_input', {}).get('file_path', '')
    if not isinstance(fp, str):
        sys.exit(1)
    print(fp)
except Exception:
    sys.exit(1)
PYEOF
)
if [[ $? -ne 0 ]] || [[ -z "$FILE_PATH" ]]; then
  exit 0  # Advisory hook — don't block on parse failure
fi

# Only check .sh files
case "$FILE_PATH" in
  *.sh) ;;
  *) exit 0 ;;
esac

# P2 fix: use git -C to target file's repo, not CWD's repo
FILE_DIR=$(dirname "$FILE_PATH")
REPO_RELATIVE_PATH="$FILE_PATH"
if git -C "$FILE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO_ROOT=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$REPO_ROOT" ]]; then
    # Canonicalize both paths to handle symlinks/.. before computing relative path
    CANON_FILE=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && echo "$(pwd -P)/$(basename "$FILE_PATH")")
    CANON_ROOT=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)
    if [[ -n "$CANON_FILE" && -n "$CANON_ROOT" && "$CANON_FILE" == "$CANON_ROOT"/* ]]; then
      REPO_RELATIVE_PATH="${CANON_FILE#"$CANON_ROOT"/}"
    fi
  fi
  if git -C "$FILE_DIR" ls-files --error-unmatch "$REPO_RELATIVE_PATH" >/dev/null 2>&1; then
    exit 0
  fi
fi

# --- Check for associated test file ---
DIR=$(dirname "$FILE_PATH")
BASE=$(basename "$FILE_PATH" .sh)
WARNINGS=""

# Look for test_<name>.sh or <name>.test.sh in same dir
if [[ ! -f "${DIR}/test_${BASE}.sh" ]] && [[ ! -f "${DIR}/${BASE}.test.sh" ]]; then
  WARNINGS="No test file found"
fi

# --- Check for DESIGN.md in same dir or parent ---
if [[ ! -f "${DIR}/DESIGN.md" ]] && [[ ! -f "$(dirname "$DIR")/DESIGN.md" ]]; then
  if [[ -n "$WARNINGS" ]]; then
    WARNINGS="${WARNINGS}. No DESIGN.md found"
  else
    WARNINGS="No DESIGN.md found"
  fi
fi

# P1+P2 fix: sanitize untrusted values, use safe_json if available
if [[ -n "$WARNINGS" ]]; then
  # Sanitize BASE (derived from untrusted FILE_PATH)
  SAFE_BASE=$(sanitize_input "$BASE" 100 2>/dev/null || echo "$BASE" | tr -cd 'a-zA-Z0-9._-' | head -c 100)
  SAFE_WARNINGS=$(sanitize_input "$WARNINGS" 500 2>/dev/null || echo "$WARNINGS" | tr -cd 'a-zA-Z0-9._ /-' | head -c 500)

  if declare -F safe_json >/dev/null 2>&1; then
    # Use shared library for proper JSON encoding
    python3 - "$SAFE_BASE" "$SAFE_WARNINGS" << 'PYEOF'
import json, sys
output = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": f"ADVISORY: New script '{sys.argv[1]}.sh' — {sys.argv[2]}. Consider adding before dispatching for review."
    }
}
print(json.dumps(output))
PYEOF
  else
    # Fallback if validate.sh failed to load
    python3 - "$SAFE_BASE" "$SAFE_WARNINGS" << 'PYEOF'
import json, sys
output = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": f"ADVISORY: New script '{sys.argv[1]}.sh' — {sys.argv[2]}. Consider adding before dispatching for review."
    }
}
print(json.dumps(output))
PYEOF
  fi
fi

exit 0
