#!/bin/bash
# validate.sh — Shared validation library for all MyndAIX runners and hooks
# Sourced (not executed) by runners, watchers, and hooks.
# Every function fails closed — deny by default, allow only on explicit pass.
#
# Usage: source "$BRIDGE_DIR/watchers/lib/validate.sh"

VALIDATE_LIB_VERSION="1.1.0"

# --- Dependency check ---
command -v python3 >/dev/null 2>&1 || { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] FATAL: python3 not found" >&2; return 1 2>/dev/null || exit 1; }

# --- Resolve paths ---
VALIDATE_BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
VALIDATE_TRUSTED_SENDERS_FILE="${VALIDATE_BRIDGE_DIR}/state/trusted-senders.conf"
VALIDATE_PATTERNS_FILE="${VALIDATE_BRIDGE_DIR}/patterns.yaml"
VALIDATE_TASK_COUNT_DIR="${VALIDATE_BRIDGE_DIR}/state"
VALIDATE_DENIAL_LOG="${VALIDATE_BRIDGE_DIR}/logs/denials.log"

# ============================================================
# parse_frontmatter(file)
#   Extract YAML frontmatter fields from a task .md file.
#   Outputs JSON object with all frontmatter fields.
#   Returns 1 if frontmatter missing, malformed, or required fields absent.
#   Required fields: from, to, type, subject
# ============================================================
parse_frontmatter() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] parse_frontmatter: file not found: $file" >&2
    return 1
  fi

  local json
  json=$(python3 - "$file" << 'PYEOF'
import sys, re, json, yaml

filepath = sys.argv[1]
try:
    with open(filepath, 'r') as f:
        content = f.read()
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(1)

# Extract frontmatter between --- delimiters
m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not m:
    print(json.dumps({"error": "no frontmatter found"}))
    sys.exit(1)

# P1 fix: use yaml.safe_load instead of naive line parser
# Prevents field spoofing via multi-line YAML values
try:
    data = yaml.safe_load(m.group(1))
except yaml.YAMLError as e:
    print(json.dumps({"error": f"YAML parse error: {e}"}))
    sys.exit(1)

if not isinstance(data, dict):
    print(json.dumps({"error": "frontmatter is not a mapping"}))
    sys.exit(1)

# Single-value fields: strip control chars + newlines
single_fields = {'from', 'to', 'type', 'subject', 'tier', 'task_id',
                 'priority', 'status', 'chain_id', 'chain_depth', 'repo', 'branch'}

fields = {}
for key, val in data.items():
    key = str(key).strip().lower()
    if val is None:
        val = ''
    else:
        val = str(val)

    if key in single_fields:
        val = ''.join(c for c in val if c.isprintable())
    else:
        val = ''.join(c for c in val if c.isprintable() or c in ('\n', '\t'))

    fields[key] = val

# Validate required fields
required = ['from', 'to', 'type', 'subject']
missing = [f for f in required if not fields.get(f)]
if missing:
    print(json.dumps({"error": f"missing required fields: {', '.join(missing)}"}))
    sys.exit(1)

print(json.dumps(fields))
PYEOF
  )
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] parse_frontmatter: failed to parse $file" >&2
    return 1
  fi

  # Check for error in JSON output
  local err
  err=$(echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
  if [[ -n "$err" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] parse_frontmatter: $err" >&2
    return 1
  fi

  echo "$json"
  return 0
}

# ============================================================
# sanitize_input(string, [max_len])
#   Strip control chars (except \n \t), cap length, strip fence tags.
#   Default max_len: 10000
# ============================================================
sanitize_input() {
  local input="$1"
  local max_len="${2:-10000}"

  python3 - "$input" "$max_len" << 'PYEOF'
import sys

text = sys.argv[1]
max_len = int(sys.argv[2])

# Strip non-printable control chars (keep newline, tab)
cleaned = ''.join(c for c in text if c.isprintable() or c in ('\n', '\t'))

# Strip closing data fence tags (prompt injection defense)
for tag in ['</task_content>', '</user_input>', '</system>', '</assistant>']:
    cleaned = cleaned.replace(tag, '')

# Cap length
cleaned = cleaned[:max_len]

print(cleaned, end='')
PYEOF
}

# ============================================================
# sanitize_output(string, [max_len])
#   Same as sanitize_input + match against patterns.yaml injection patterns.
#   Strips or flags matches based on severity.
#   Default max_len: 10000
# ============================================================
sanitize_output() {
  local input="$1"
  local max_len="${2:-10000}"
  local patterns_file="${VALIDATE_PATTERNS_FILE}"

  # First apply base sanitization
  local cleaned
  cleaned=$(sanitize_input "$input" "$max_len")

  # If patterns file missing, fail closed — refuse to pass unscanned output
  if [[ ! -f "$patterns_file" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] FATAL: sanitize_output: patterns.yaml not found — refusing to pass unscanned output" >&2
    return 1
  fi

  python3 - "$cleaned" "$patterns_file" << 'PYEOF'
import sys, re, yaml

text = sys.argv[1]
patterns_file = sys.argv[2]

try:
    with open(patterns_file, 'r') as f:
        data = yaml.safe_load(f)
except Exception as e:
    # Fail closed — patterns file exists but can't be loaded, reject output
    print(f"[SANITIZE_BLOCKED: patterns.yaml load failed: {e}]", file=sys.stderr)
    print("[OUTPUT BLOCKED — sanitization patterns unavailable]", end='')
    sys.exit(1)

if not isinstance(data, dict):
    print("[SANITIZE_BLOCKED: patterns.yaml has invalid format]", file=sys.stderr)
    print("[OUTPUT BLOCKED — sanitization patterns invalid]", end='')
    sys.exit(1)

# Extract all patterns across all categories
all_patterns = []
for key, val in data.items():
    if key == 'severityConfig':
        continue
    if isinstance(val, list):
        for item in val:
            if isinstance(item, dict) and 'pattern' in item:
                severity = item.get('severity', 'low')
                try:
                    compiled = re.compile(item['pattern'])
                    all_patterns.append((compiled, severity, item.get('reason', '')))
                except re.error:
                    continue

# Check text against patterns — strip high severity matches, flag medium/low
flagged = []
for pattern, severity, reason in all_patterns:
    if pattern.search(text):
        if severity == 'high':
            text = pattern.sub('[REDACTED]', text)
            flagged.append(f"HIGH: {reason}")
        elif severity == 'medium':
            flagged.append(f"MEDIUM: {reason}")

if flagged:
    print(f"[SANITIZED: {'; '.join(flagged)}]\n", end='', file=sys.stderr)

print(text, end='')
PYEOF
}

# ============================================================
# safe_json(key1, value1, key2, value2, ...)
#   Generate properly escaped JSON from key-value pairs.
#   All values passed via sys.argv — never interpolated.
# ============================================================
safe_json() {
  python3 - "$@" << 'PYEOF'
import sys, json

args = sys.argv[1:]
if len(args) % 2 != 0:
    print("{}", end='')
    sys.exit(1)

obj = {}
for i in range(0, len(args), 2):
    key = args[i]
    val = args[i + 1]
    obj[key] = val

print(json.dumps(obj, ensure_ascii=False))
PYEOF
}

# ============================================================
# pre_task_gate(task_file)
#   Pre-execution checks. Returns 0 (proceed) or 1 (blocked).
#   Reason written to stderr on block.
# ============================================================
pre_task_gate() {
  local task_file="$1"
  local daily_cap="${VALIDATE_DAILY_TASK_CAP:-30}"

  # --- Parse frontmatter ---
  local fm
  fm=$(parse_frontmatter "$task_file")
  if [[ $? -ne 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — failed to parse frontmatter" >&2
    return 1
  fi

  # P1-2 fix: fail closed on Python extraction errors (no 2>/dev/null)
  # --- Check 1: Trusted sender ---
  local sender
  sender=$(echo "$fm" | python3 -c "import json,sys; print(json.load(sys.stdin).get('from',''))")
  if [[ $? -ne 0 || -z "$sender" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — failed to extract sender from frontmatter" >&2
    _log_denial "sender extraction failed" "$task_file"
    return 1
  fi

  if [[ -f "$VALIDATE_TRUSTED_SENDERS_FILE" ]]; then
    if ! grep -Fxq "$sender" "$VALIDATE_TRUSTED_SENDERS_FILE" 2>/dev/null; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — untrusted sender: $sender" >&2
      _log_denial "untrusted sender: $sender" "$task_file"
      return 1
    fi
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — trusted-senders.conf not found, failing closed" >&2
    _log_denial "trusted-senders.conf missing — fail closed" "$task_file"
    return 1
  fi

  # --- Check 2: Git clean (if repo specified) ---
  local repo
  repo=$(echo "$fm" | python3 -c "import json,sys; print(json.load(sys.stdin).get('repo',''))")
  if [[ $? -ne 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — failed to extract repo from frontmatter" >&2
    _log_denial "repo extraction failed" "$task_file"
    return 1
  fi

  if [[ -n "$repo" ]] && [[ -d "$repo" ]]; then
    if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      local dirty
      dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
      if [[ -n "$dirty" ]]; then
        local count
        count=$(echo "$dirty" | wc -l | tr -d ' ')
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — $count uncommitted file(s) in $repo" >&2
        _log_denial "uncommitted changes in $repo ($count files)" "$task_file"
        return 1
      fi
    fi
  fi

  # --- Check 3: Daily task cap (atomic mkdir lock) ---
  local today
  today=$(date '+%Y%m%d')
  local count_file="${VALIDATE_TASK_COUNT_DIR}/task-count-${today}.txt"
  local lock_dir="${VALIDATE_TASK_COUNT_DIR}/task-count.lock"

  # Acquire lock (atomic mkdir)
  local lock_acquired=false
  for i in 1 2 3 4 5; do
    if mkdir "$lock_dir" 2>/dev/null; then
      lock_acquired=true
      break
    fi
    # Check for stale lock (older than 30 seconds)
    if [[ -d "$lock_dir" ]]; then
      local lock_age
      # P2-3 fix: on getmtime failure, treat lock as stale (9999) not fresh (0)
      lock_age=$(python3 - "$lock_dir" << 'PYEOF'
import os, sys, time
try:
    age = time.time() - os.path.getmtime(sys.argv[1])
    print(int(age))
except Exception:
    print(9999)
PYEOF
)
      if [[ "${lock_age:-0}" -gt 30 ]]; then
        rm -rf "$lock_dir" 2>/dev/null
        continue
      fi
    fi
    sleep 1
  done

  if [[ "$lock_acquired" = false ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — could not acquire task count lock after 5 attempts" >&2
    _log_denial "task count lock acquisition failed" "$task_file"
    return 1
  else
    # Read current count, increment, write back
    local current_count=0
    if [[ -f "$count_file" ]]; then
      current_count=$(cat "$count_file" 2>/dev/null | tr -cd '0-9')
      current_count=${current_count:-0}
    fi

    if [[ "$current_count" -ge "$daily_cap" ]]; then
      rm -rf "$lock_dir" 2>/dev/null
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — daily task cap reached ($current_count/$daily_cap)" >&2
      _log_denial "daily task cap reached ($current_count/$daily_cap)" "$task_file"
      return 1
    fi

    echo "$((current_count + 1))" > "$count_file"
    rm -rf "$lock_dir" 2>/dev/null
  fi

  # --- Check 4: Scope required for review tasks ---
  local task_type
  task_type=$(echo "$fm" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")
  if [[ $? -ne 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: BLOCKED — failed to extract type from frontmatter" >&2
    _log_denial "type extraction failed" "$task_file"
    return 1
  fi

  if [[ "$task_type" == "review" ]]; then
    local has_scope
    has_scope=$(echo "$fm" | python3 -c "
import json, sys
d = json.load(sys.stdin)
has = bool(d.get('scope') or d.get('branch'))
print('yes' if has else 'no')
")
    if [[ "$has_scope" != "yes" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate] pre_task_gate: WARNING — review task missing scope/branch, proceeding" >&2
    fi
  fi

  return 0
}

# ============================================================
# fail_closed_deny(reason)
#   Standard deny JSON for Claude Code hooks.
#   Also logs to denials.log.
# ============================================================
fail_closed_deny() {
  local reason="$1"
  local hook_event="${2:-PreToolUse}"

  # Log the denial
  _log_denial "$reason" ""

  # Output hook-compatible deny JSON
  safe_json \
    "hookSpecificOutput.hookEventName" "$hook_event" \
    "hookSpecificOutput.permissionDecision" "deny" \
    "hookSpecificOutput.reason" "BLOCKED: $reason" | python3 -c "
import json, sys
flat = json.load(sys.stdin)
# Unflatten dotted keys into nested structure
result = {}
for key, val in flat.items():
    parts = key.split('.')
    d = result
    for p in parts[:-1]:
        d = d.setdefault(p, {})
    d[parts[-1]] = val
print(json.dumps(result))
"
}

# ============================================================
# _log_denial(reason, task_file)
#   Internal: append denial to log file.
# ============================================================
_log_denial() {
  local reason="$1"
  local task_file="${2:-unknown}"
  local log_dir
  log_dir=$(dirname "$VALIDATE_DENIAL_LOG")

  mkdir -p "$log_dir" 2>/dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DENIED: $reason | file=$task_file" >> "$VALIDATE_DENIAL_LOG" 2>/dev/null
}
