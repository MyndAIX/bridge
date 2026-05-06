#!/bin/bash
set -euo pipefail
#
# resolve-pointers.sh — MyndAIX Encrypted Knowledge Pointer Resolver v1.0
#
# SECURITY-CRITICAL: This script is the trust anchor for the pointer system.
#
# What it does:
#   1. Reads task content from stdin
#   2. Finds {{pointer:filename.md}} references
#   3. Validates agent access against .manifest.yaml
#   4. Reads file content at CHECK TIME (not path — content-based security)
#   5. Replaces pointers with resolved content inline
#   6. Outputs resolved content to stdout
#
# What it enforces:
#   - Content-based security: passes content, never paths (TOCTOU fix)
#   - Per-agent access tiers from manifest
#   - 100KB total resolved content budget
#   - No recursive pointer resolution
#   - Silent failure: unauthorized = empty string, no metadata leak
#   - Audit log for every resolution attempt
#   - Fail closed: any error = empty string
#
# Usage:
#   echo "$TASK_CONTENT" | resolve-pointers.sh --agent mack --task-id MX-001
#

PROTECTED_DIR="$HOME/.myndaix/protected"
MANIFEST="$PROTECTED_DIR/.manifest.yaml"
AUDIT_LOG="$HOME/.myndaix/logs/pointer-audit.log"
MAX_RESOLVED_BYTES=102400  # 100KB budget

# ── Args ──────────────────────────────────────────────────────────────────────

AGENT_ID=""
TASK_ID="unknown"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT_ID="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$AGENT_ID" ]]; then
  echo "ERROR: --agent is required" >&2
  exit 1
fi

# Sanitize agent ID — alphanumeric + dash only
AGENT_ID=$(echo "$AGENT_ID" | tr -cd 'a-zA-Z0-9-')

# ── Audit logging ─────────────────────────────────────────────────────────────

audit() {
  local action="$1"
  local detail="$2"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "$ts agent=$AGENT_ID task=$TASK_ID action=$action $detail" >> "$AUDIT_LOG" 2>/dev/null || true
}

# ── Manifest lookup ───────────────────────────────────────────────────────────

# Check if agent has access to a file in the manifest
# Returns 0 (has access) or 1 (no access)
check_access() {
  local filename="$1"
  local agent="$2"

  if [[ ! -f "$MANIFEST" ]]; then
    audit "DENIED" "file=$filename reason=no_manifest"
    return 1
  fi

  # Parse manifest — simple YAML subset parser (no pyyaml dependency)
  python3 -c "
import sys, re

manifest_path = sys.argv[1]
filename = sys.argv[2]
agent = sys.argv[3]

try:
    with open(manifest_path) as f:
        content = f.read()
except Exception:
    sys.exit(1)

# Find all file entries: '- name: X' followed by 'agents: [...]'
entries = re.findall(
    r'-\s*name:\s*(.+?)\n\s*(?:description:[^\n]*\n\s*)?agents:\s*\[([^\]]*)\]',
    content
)

for name, agents_str in entries:
    name = name.strip()
    agents = [a.strip() for a in agents_str.split(',')]
    if name == filename:
        if 'all' in agents or agent in agents:
            sys.exit(0)
        else:
            sys.exit(1)

# File not in manifest
sys.exit(1)
" "$MANIFEST" "$filename" "$agent" 2>/dev/null
}

# ── Resolve a single pointer ─────────────────────────────────────────────────

# Returns resolved content on stdout, empty string on any failure
resolve_one() {
  local filename="$1"

  # Sanitize filename — no path separators, no dots-dots
  if [[ "$filename" == *"/"* ]] || [[ "$filename" == *".."* ]]; then
    audit "BLOCKED" "file=$filename reason=path_traversal"
    return 0  # silent failure — return empty
  fi

  # Build full path and validate with realpath
  local full_path="$PROTECTED_DIR/$filename"

  if [[ ! -f "$full_path" ]]; then
    # Silent failure — don't reveal whether file exists
    audit "MISS" "file=$filename reason=not_found"
    return 0
  fi

  local real_path
  real_path=$(realpath "$full_path" 2>/dev/null) || {
    audit "BLOCKED" "file=$filename reason=realpath_failed"
    return 0
  }

  # Verify resolved path is inside protected dir (symlink guard)
  local real_protected
  real_protected=$(realpath "$PROTECTED_DIR" 2>/dev/null) || return 0

  if [[ "$real_path" != "$real_protected/"* ]]; then
    audit "BLOCKED" "file=$filename reason=outside_protected_dir resolved=$real_path"
    return 0
  fi

  # Check agent access tier
  if ! check_access "$filename" "$AGENT_ID"; then
    audit "DENIED" "file=$filename reason=agent_not_authorized"
    return 0  # silent failure
  fi

  # Read content at CHECK TIME — this is the TOCTOU fix
  # We read NOW and pass content, executor never re-opens this path
  local content
  content=$(cat "$real_path" 2>/dev/null) || {
    audit "ERROR" "file=$filename reason=read_failed"
    return 0
  }

  local content_bytes
  content_bytes=$(echo "$content" | wc -c | tr -d ' ')

  audit "RESOLVED" "file=$filename bytes=$content_bytes"

  # Output the content
  echo "$content"
}

# ── Main: process stdin, resolve pointers ─────────────────────────────────────

audit "START" "resolver_invoked"

# Read full task content from stdin
TASK_CONTENT=$(cat)

# Find all {{pointer:filename.md}} references
POINTERS=$(echo "$TASK_CONTENT" | grep -oE '\{\{pointer:[^}]+\}\}' || true)

if [[ -z "$POINTERS" ]]; then
  # No pointers — pass through unchanged
  echo "$TASK_CONTENT"
  audit "DONE" "no_pointers_found"
  exit 0
fi

TOTAL_RESOLVED_BYTES=0
RESOLVED_CONTENT="$TASK_CONTENT"

while IFS= read -r pointer; do
  [[ -z "$pointer" ]] && continue

  # Extract filename from {{pointer:filename.md}}
  filename=$(echo "$pointer" | sed 's/{{pointer:\(.*\)}}/\1/' | tr -d ' ')

  # Resolve content
  content=$(resolve_one "$filename")

  if [[ -n "$content" ]]; then
    # Strip any nested {{pointer:...}} from resolved content (anti-recursion)
    content=$(echo "$content" | sed 's/{{pointer:[^}]*}}//g')

    # Check budget
    content_bytes=$(echo "$content" | wc -c | tr -d ' ')
    TOTAL_RESOLVED_BYTES=$((TOTAL_RESOLVED_BYTES + content_bytes))

    if (( TOTAL_RESOLVED_BYTES > MAX_RESOLVED_BYTES )); then
      audit "BUDGET_EXCEEDED" "total=${TOTAL_RESOLVED_BYTES} max=${MAX_RESOLVED_BYTES} dropped=$filename"
      # Budget exceeded — replace with empty (silent)
      RESOLVED_CONTENT=$(echo "$RESOLVED_CONTENT" | sed "s|$(echo "$pointer" | sed 's/[[\\.^$*+?()|{]/\\&/g')||g")
      continue
    fi

    # Replace pointer with resolved content
    # Use python for safe string replacement (sed chokes on multi-line content)
    RESOLVED_CONTENT=$(python3 -c "
import sys
content = sys.stdin.read()
pointer = sys.argv[1]
replacement = sys.argv[2]
print(content.replace(pointer, replacement), end='')
" "$pointer" "$content" <<< "$RESOLVED_CONTENT")
  else
    # Resolution failed (silent) — remove the pointer tag entirely
    RESOLVED_CONTENT=$(python3 -c "
import sys
content = sys.stdin.read()
pointer = sys.argv[1]
print(content.replace(pointer, ''), end='')
" "$pointer" <<< "$RESOLVED_CONTENT")
  fi

done <<< "$POINTERS"

audit "DONE" "pointers_resolved total_bytes=$TOTAL_RESOLVED_BYTES"

echo "$RESOLVED_CONTENT"
