#!/usr/bin/env bash
# systems-check.sh — Layer 2: Pre-review health check for /feature pipeline
# Run before dispatching to KilaBz/Oracle — catches architecture anti-patterns at build time
# Exit 0 = clean, exit 0 with warnings printed = issues found (advisory, non-blocking)
set -euo pipefail

# Usage: systems-check.sh <file1> [file2] [file3] ...
# Checks the given files for known anti-patterns

if [[ $# -eq 0 ]]; then
  echo "Usage: systems-check.sh <file1> [file2] ..."
  echo "Checks files for known architecture anti-patterns before review"
  exit 0
fi

WARNINGS=0
warn() {
  echo "⚠️  $1"
  WARNINGS=$((WARNINGS + 1))
}

for file in "$@"; do
  [[ -f "$file" ]] || continue
  local_name="$(basename "$file")"
  ext="${local_name##*.}"

  # --- Bash script checks ---
  if [[ "$ext" == "sh" ]]; then

    # Check: shared state mutation without flock
    if grep -q 'open.*\"a\"\|>> \|> .*\.json\|> .*\.jsonl' "$file" 2>/dev/null; then
      if ! grep -q 'flock\|fcntl\.flock\|LOCK' "$file" 2>/dev/null; then
        warn "$local_name: writes to shared file without flock/lock — race condition risk"
      fi
    fi

    # Check: 2>/dev/null || true on security-critical paths
    if grep -q '2>/dev/null || true' "$file" 2>/dev/null; then
      warn "$local_name: suppresses errors with 2>/dev/null || true — may hide failures"
    fi

    # Check: eval on variables
    if grep -q 'eval "\$\|eval $' "$file" 2>/dev/null; then
      warn "$local_name: uses eval on variable — command injection risk (P0)"
    fi

    # Check: missing set -euo pipefail
    if ! head -5 "$file" | grep -q 'set -euo pipefail' 2>/dev/null; then
      warn "$local_name: missing 'set -euo pipefail' in header"
    fi

    # Check: missing trap for cleanup
    if grep -q 'mktemp\|tmp=' "$file" 2>/dev/null; then
      if ! grep -q 'trap.*EXIT\|trap.*rm' "$file" 2>/dev/null; then
        warn "$local_name: creates temp files but has no cleanup trap"
      fi
    fi

    # Check: kill without PID validation
    if grep -q 'kill "\$' "$file" 2>/dev/null; then
      if ! grep -q '\^[0-9]\+\$\|=~ .*[0-9]' "$file" 2>/dev/null; then
        warn "$local_name: kill without numeric PID validation"
      fi
    fi

    # Check: python3 -c with interpolated variables
    if grep -q "python3 -c.*\\\$" "$file" 2>/dev/null; then
      if ! grep -q 'sys\.argv' "$file" 2>/dev/null; then
        warn "$local_name: python3 -c with shell variable interpolation — use sys.argv instead"
      fi
    fi

    # Check: shared marker files
    if grep -q 'marker\|\.marker' "$file" 2>/dev/null; then
      if ! grep -q 'SESSION_ID\|per-instance\|PER_INSTANCE' "$file" 2>/dev/null; then
        warn "$local_name: uses marker file — ensure per-instance, not shared across consumers"
      fi
    fi

    # Check: no test file exists
    test_file="${file%.sh}.test.sh"
    test_file2="test_$(basename "$file")"
    if [[ ! -f "$test_file" && ! -f "$(dirname "$file")/$test_file2" ]]; then
      warn "$local_name: no test script found (expected ${test_file} or ${test_file2})"
    fi
  fi

  # --- Python script checks ---
  if [[ "$ext" == "py" ]]; then
    if grep -q "open(.*'a')" "$file" 2>/dev/null; then
      if ! grep -q 'flock\|fcntl' "$file" 2>/dev/null; then
        warn "$local_name: appends to file without lock — concurrent write risk"
      fi
    fi
  fi

  # --- JSON checks ---
  if [[ "$ext" == "json" ]]; then
    if ! python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
      warn "$local_name: invalid JSON syntax"
    fi
  fi
done

# Summary
if (( WARNINGS > 0 )); then
  echo ""
  echo "📋 systems-check: ${WARNINGS} warning(s) found. Review before dispatching."
  echo "   These are advisory — fix what's real, skip what's intentional."
else
  echo "✅ systems-check: all files clean. No anti-patterns detected."
fi

# Touch the marker pre-dispatch-gate.sh looks for (60-min TTL).
# Without this, the gate blocks every SCP even after a clean run.
MARKER_DIR="$HOME/.myndaix/bridge/state"
mkdir -p "$MARKER_DIR"
touch "$MARKER_DIR/systems-check-ran.marker"
