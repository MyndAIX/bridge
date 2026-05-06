#!/bin/bash
set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
except Exception:
  print("")
  raise SystemExit(0)
path=(d.get("tool_input") or {}).get("file_path") or ""
print(path)')

if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
  exit 0
fi

ext="${FILE_PATH##*.}"
ext="${ext,,}"

fail() {
  echo "$1" >&2
  exit 1
}

case "$ext" in
  swift)
    if command -v swiftc >/dev/null 2>&1; then
      swiftc -parse "$FILE_PATH" >/dev/null 2>&1 || fail "Swift syntax check failed: $FILE_PATH"
    fi
    ;;
  py)
    python3 -m py_compile "$FILE_PATH" >/dev/null 2>&1 || fail "Python syntax check failed: $FILE_PATH"
    ;;
  js|cjs|mjs)
    if command -v node >/dev/null 2>&1; then
      node --check "$FILE_PATH" >/dev/null 2>&1 || fail "JavaScript syntax check failed: $FILE_PATH"
    fi
    ;;
  ts|tsx)
    if command -v npx >/dev/null 2>&1 && [[ -f "tsconfig.json" ]]; then
      npx tsc --noEmit --allowJs >/dev/null 2>&1 || fail "TypeScript syntax check failed (tsc): $FILE_PATH"
    fi
    ;;
  json)
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FILE_PATH" >/dev/null 2>&1 || fail "JSON syntax check failed: $FILE_PATH"
    ;;
  *)
    ;;
esac

exit 0
