#!/bin/bash
set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
except Exception:
  print("")
  raise SystemExit(0)
print((d.get("tool_input") or {}).get("command", ""))')

if [[ -z "$CMD" ]]; then
  exit 0
fi

if echo "$CMD" | grep -qiE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]+[^;&|]+)*[[:space:]](origin[[:space:]]+)?(main|master)([[:space:]]|$)'; then
  echo "Blocked: pushing directly to main/master is not allowed." >&2
  exit 2
fi
if echo "$CMD" | grep -qiE '(^|[;&|[:space:]])git[[:space:]]+(checkout|switch)[[:space:]]+(-[A-Za-z][[:space:]]+)*((main|master))(\b|$)'; then
  echo "Blocked: direct checkout/switch to main/master is not allowed." >&2
  exit 2
fi
if echo "$CMD" | grep -qiE '(^|[;&|[:space:]])git[[:space:]]+merge([[:space:]]+[^;&|]+)*[[:space:]](main|master)([[:space:]]|$)'; then
  echo "Blocked: merging main/master into working branches is not allowed." >&2
  exit 2
fi

exit 0
