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

PATTERNS=(
  '(^|[;&|[:space:]])rm[[:space:]]+-([[:alnum:]]*r[[:alnum:]]*f|[[:alnum:]]*f[[:alnum:]]*r)([[:space:]]|$)'
  '(^|[;&|[:space:]])find[[:space:]].*-delete([[:space:]]|$)'
  '(^|[;&|[:space:]])git[[:space:]]+reset[[:space:]]+--hard([[:space:]]|$)'
  '(^|[;&|[:space:]])git[[:space:]]+checkout[[:space:]]+\.(\.[^[:alnum:]]*)?([[:space:]]|$)'
  '(^|[;&|[:space:]])git[[:space:]]+restore([[:space:]]+--source=[^[:space:]]+)?[[:space:]]+\.(\.[^[:alnum:]]*)?([[:space:]]|$)'
  '(^|[;&|[:space:]])git[[:space:]]+clean([[:space:]]+[^;&|]+)*([[:space:]]|$)'
  '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]+[^;&|]+)*[[:space:]]+(-f|--force)([[:space:]]|$)'
  '(^|[;&|[:space:]])drop[[:space:]]+table([[:space:]]|$)'
  '(^|[;&|[:space:]])drop[[:space:]]+database([[:space:]]|$)'
  '(^|[;&|[:space:]])truncate([[:space:]]+table)?([[:space:]]|$)'
)

for pattern in "${PATTERNS[@]}"; do
  if echo "$CMD" | grep -qiE "$pattern"; then
    echo "Blocked destructive command by policy." >&2
    exit 2
  fi
done

exit 0
