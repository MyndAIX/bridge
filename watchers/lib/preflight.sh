#!/usr/bin/env bash
# preflight.sh — Pre-flight clarity check for task validation
# Source this file: source "$(dirname "$0")/lib/preflight.sh"
#
# Runs AFTER schema validation, BEFORE engine execution.
# Returns 0 (clear) or 1 (warnings found) with diagnostic messages on stderr.
# No side effects on source — all logic in functions.

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
PREFLIGHT_LOCK_DIR="${BRIDGE_DIR}/locks"
PREFLIGHT_MAX_SCOPE_FILES=10
PREFLIGHT_MIN_OBJECTIVE_WORDS=10

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _preflight_log <message>
_preflight_log() {
  if declare -f log >/dev/null 2>&1; then
    log "[preflight] $1"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [preflight] $1" >&2
  fi
}

# _preflight_warn <message>
# Appends warning to the warnings array and logs it.
_preflight_warn() {
  _PREFLIGHT_WARNINGS+=("$1")
  _preflight_log "WARN: $1"
}

# ---------------------------------------------------------------------------
# 1. Repo Check
# ---------------------------------------------------------------------------
# Usage: preflight_check_repo <repo_path>
# Returns 0 if repo exists and is a git repo, 1 otherwise.
preflight_check_repo() {
  local repo_path="$1"

  if [[ -z "$repo_path" ]]; then
    _preflight_warn "repo path is empty"
    return 1
  fi

  if [[ ! -d "$repo_path" ]]; then
    _preflight_warn "repo does not exist: $repo_path"
    return 1
  fi

  if [[ ! -d "$repo_path/.git" ]] && [[ ! -f "$repo_path/.git" ]]; then
    _preflight_warn "not a git repo: $repo_path"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# 2. Branch Check
# ---------------------------------------------------------------------------
# Usage: preflight_check_branch <repo_path> <branch_name>
# Returns 0 if branch exists or can be created, 1 on error.
preflight_check_branch() {
  local repo_path="$1"
  local branch_name="$2"

  if [[ -z "$branch_name" ]]; then
    # No branch specified — not an error, engine will decide
    return 0
  fi

  if [[ ! -d "$repo_path" ]]; then
    return 1
  fi

  # Validate branch name format
  if ! git check-ref-format --branch "$branch_name" &>/dev/null; then
    _preflight_warn "invalid branch name format: $branch_name"
    return 1
  fi

  # Branch already exists (local or remote)
  if git -C "$repo_path" rev-parse --verify --end-of-options "refs/heads/$branch_name" &>/dev/null; then
    return 0
  fi

  if git -C "$repo_path" rev-parse --verify --end-of-options "refs/remotes/origin/$branch_name" &>/dev/null; then
    return 0
  fi

  # Branch doesn't exist — check if we can create it (repo has commits)
  if git -C "$repo_path" rev-parse HEAD &>/dev/null; then
    return 0  # Can create branch from HEAD
  fi

  _preflight_warn "branch '$branch_name' does not exist and repo has no commits"
  return 1
}

# ---------------------------------------------------------------------------
# 3. Scope File Check
# ---------------------------------------------------------------------------
# Usage: preflight_check_scope_files <repo_path> <file1> [file2] ...
# Returns 0 if all files exist and are readable, 1 if any are missing.
preflight_check_scope_files() {
  local repo_path="$1"
  shift
  local files=("$@")
  local missing=0

  if [[ ${#files[@]} -eq 0 ]]; then
    _preflight_warn "scope.in is empty — no target files specified"
    return 1
  fi

  for f in "${files[@]}"; do
    local full_path
    # Reject absolute paths — scope files must be relative to repo
    if [[ "$f" = /* ]]; then
      _preflight_warn "absolute path in scope.in rejected (must be relative to repo): $f"
      missing=1
      continue
    fi
    # Reject path traversal
    if [[ "$f" == *".."* ]]; then
      _preflight_warn "path traversal in scope.in rejected: $f"
      missing=1
      continue
    fi
    full_path="$repo_path/$f"
    # Canonicalize and verify it stays under repo_path
    local resolved
    resolved=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$full_path" 2>/dev/null) || resolved="$full_path"
    local resolved_repo
    resolved_repo=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$repo_path" 2>/dev/null) || resolved_repo="$repo_path"
    if [[ "$resolved" != "$resolved_repo"* ]]; then
      _preflight_warn "scope file resolves outside repo boundary: $f"
      missing=1
      continue
    fi

    # File might not exist yet (new file creation is valid)
    # But check if parent directory exists
    local parent_dir
    parent_dir=$(dirname "$full_path")
    if [[ ! -d "$parent_dir" ]]; then
      _preflight_warn "parent directory does not exist for scope file: $f"
      missing=1
    fi
  done

  return $missing
}

# ---------------------------------------------------------------------------
# 4. Ambiguity Detector
# ---------------------------------------------------------------------------
# Usage: preflight_check_ambiguity <objective> <scope_in_count>
# Returns 0 if clear, 1 if ambiguous.
preflight_check_ambiguity() {
  local objective="$1"
  local scope_in_count="$2"
  local ambiguous=0

  if [[ -z "$objective" ]]; then
    _preflight_warn "objective is empty"
    return 1
  fi

  # Count words in objective
  local word_count
  word_count=$(echo "$objective" | wc -w | tr -d ' ')

  if (( word_count < PREFLIGHT_MIN_OBJECTIVE_WORDS )); then
    _preflight_warn "objective is only $word_count words (min $PREFLIGHT_MIN_OBJECTIVE_WORDS) — may be too vague"
    ambiguous=1
  fi

  if [[ "$scope_in_count" -eq 0 ]] 2>/dev/null; then
    _preflight_warn "scope.in is empty — task has no file targets"
    ambiguous=1
  fi

  return $ambiguous
}

# ---------------------------------------------------------------------------
# 5. Complexity Estimate
# ---------------------------------------------------------------------------
# Usage: preflight_check_complexity <file_count>
# Returns 0 if under threshold, 1 if over.
preflight_check_complexity() {
  local file_count="$1"

  if ! [[ "$file_count" =~ ^[0-9]+$ ]]; then
    _preflight_warn "invalid file count: $file_count"
    return 1
  fi

  if (( file_count > PREFLIGHT_MAX_SCOPE_FILES )); then
    _preflight_warn "scope touches $file_count files (threshold: $PREFLIGHT_MAX_SCOPE_FILES) — high complexity"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# 6. Conflict Detector
# ---------------------------------------------------------------------------
# Usage: preflight_check_conflicts <scope_file1> [scope_file2] ...
# Checks if any scope.in files overlap with active task lock files.
# Returns 0 if no conflicts, 1 if overlap found.
preflight_check_conflicts() {
  local scope_files=("$@")
  local conflict=0

  if [[ ! -d "$PREFLIGHT_LOCK_DIR" ]]; then
    return 0  # No locks dir = no conflicts
  fi

  # Look for scope lock files that track active task file ownership
  local lock_file
  local -a lock_files=()
  while IFS= read -r -d '' lf; do
    lock_files+=("$lf")
  done < <(find "$PREFLIGHT_LOCK_DIR" -maxdepth 1 -name '*.scope' -print0 2>/dev/null)
  [[ ${#lock_files[@]} -eq 0 ]] && return 0; for lock_file in "${lock_files[@]}"; do
    [[ -f "$lock_file" ]] || continue

    for scope_f in "${scope_files[@]}"; do
      if grep -qxF "$scope_f" "$lock_file" 2>/dev/null; then
        local lock_name
        lock_name=$(basename "$lock_file" .scope)
        _preflight_warn "file '$scope_f' overlaps with active task: $lock_name"
        conflict=1
      fi
    done
  done

  return $conflict
}

# ---------------------------------------------------------------------------
# 7. Main Entry Point
# ---------------------------------------------------------------------------
# Usage: preflight_check <task_file>
# Parses task frontmatter and runs all checks.
# Returns 0 (all clear) or 1 (warnings found).
# Warnings are logged via _preflight_warn and collected in _PREFLIGHT_WARNINGS.
preflight_check() {
  local task_file="$1"
  _PREFLIGHT_WARNINGS=()

  if [[ ! -f "$task_file" ]]; then
    _preflight_warn "task file not found: $task_file"
    return 1
  fi

  # Parse frontmatter with python3
  local fm_json
  fm_json=$(python3 -c '
import sys, re, json
content = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", content, re.DOTALL)
if not m:
    print("{}")
    sys.exit(0)
try:
    import yaml
    data = yaml.safe_load(m.group(1)) or {}
    print(json.dumps(data, default=str))
except Exception:
    data = {}
    current_key = None
    current_sub = None
    for line in m.group(1).splitlines():
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if ":" in stripped:
            k, v = stripped.split(":", 1)
            k = k.strip()
            v = v.strip().strip("\"")
            if indent > 0 and current_key is not None:
                if not isinstance(data.get(current_key), dict):
                    data[current_key] = {}
                if v.startswith("[") and v.endswith("]"):
                    try:
                        v = json.loads(v)
                    except Exception:
                        v = [x.strip().strip("\"") for x in v[1:-1].split(",") if x.strip()]
                data[current_key][k] = v
            elif v == "" or v == "":
                current_key = k
                data[k] = {}
            else:
                current_key = None
                if v.startswith("[") and v.endswith("]"):
                    try:
                        v = json.loads(v)
                    except Exception:
                        v = [x.strip().strip("\"") for x in v[1:-1].split(",") if x.strip()]
                data[k] = v
        elif stripped.startswith("- ") and current_key:
            val = stripped[2:].strip().strip("\"")
            if current_key in data:
                if isinstance(data[current_key], dict) and current_sub:
                    if not isinstance(data[current_key].get(current_sub), list):
                        data[current_key][current_sub] = []
                    data[current_key][current_sub].append(val)
                elif isinstance(data[current_key], list):
                    data[current_key].append(val)
                else:
                    data[current_key] = [val]
    print(json.dumps(data, default=str))
' "$task_file" 2>/dev/null) || fm_json="{}"

  # Extract fields
  local repo objective
  repo=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('repo',''))" "$fm_json" 2>/dev/null)
  objective=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('objective',''))" "$fm_json" 2>/dev/null)

  # Extract scope.in as newline-separated list
  local scope_in_raw scope_in_files scope_in_count
  scope_in_raw=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
scope = d.get('scope', {})
if isinstance(scope, dict):
    sin = scope.get('in', [])
else:
    sin = []
if isinstance(sin, list):
    for x in sin:
        print(str(x))
elif isinstance(sin, str):
    print(sin)
" "$fm_json" 2>/dev/null)

  local -a scope_in_files=()
  if [[ -n "$scope_in_raw" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && scope_in_files+=("$line")
    done <<< "$scope_in_raw"
  fi
  scope_in_count=${#scope_in_files[@]}

  # --- Run checks ---

  # 1. Repo check
  if [[ -n "$repo" ]]; then
    preflight_check_repo "$repo"
  fi

  # 2. Branch check
  local branch
  branch=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('branch',''))" "$fm_json" 2>/dev/null)
  if [[ -n "$repo" ]] && [[ -n "$branch" ]]; then
    preflight_check_branch "$repo" "$branch"
  fi

  # 3. Scope file check
  if [[ -n "$repo" ]] && [[ $scope_in_count -gt 0 ]]; then
    preflight_check_scope_files "$repo" "${scope_in_files[@]}"
  fi

  # 4. Ambiguity check
  preflight_check_ambiguity "$objective" "$scope_in_count"

  # 5. Complexity check
  preflight_check_complexity "$scope_in_count"

  # 6. Conflict check
  if [[ $scope_in_count -gt 0 ]]; then
    preflight_check_conflicts "${scope_in_files[@]}"
  fi

  # --- Result ---
  if [[ ${#_PREFLIGHT_WARNINGS[@]} -gt 0 ]]; then
    _preflight_log "Pre-flight found ${#_PREFLIGHT_WARNINGS[@]} warning(s)"
    return 1
  fi

  _preflight_log "Pre-flight clear — all checks passed"
  return 0
}

# ---------------------------------------------------------------------------
# 8. Utility: Get warnings
# ---------------------------------------------------------------------------
# Usage: preflight_get_warnings
# Prints all warnings from the last preflight_check call, one per line.
preflight_get_warnings() {
  local w
  for w in "${_PREFLIGHT_WARNINGS[@]}"; do
    echo "$w"
  done
}

# Export functions for subshell use
export -f preflight_check
export -f preflight_check_repo
export -f preflight_check_branch
export -f preflight_check_scope_files
export -f preflight_check_ambiguity
export -f preflight_check_complexity
export -f preflight_check_conflicts
export -f preflight_get_warnings
export -f _preflight_log
export -f _preflight_warn
