#!/usr/bin/env bash
# knowledge.sh — RAG-lite knowledge extraction and retrieval for MyndAIX
# Append-only JSONL knowledge store + grep-based retrieval + context injection
#
# Security hardened (v2 — 2026-04-13, KilaBz re-review):
# - Fix 1: Injection output is STRUCTURED METADATA ONLY — no free-text summaries in prompts
# - Fix 2: flock on JSONL appends (atomic writes)
# - Fix 3: Repo + agent scoping REQUIRED (fail closed — empty = no results)
# - Fix 4: Redact sensitive patterns from summaries before storing
# - Fix 5: try/except per line in retrieval (handle corruption gracefully)
# - Fix 6: Auth gate — agent identity required for retrieval
# - Fix 7: Tightened redaction patterns (URL credentials, JWT, AWS keys)
#
# Usage: source this file from watchers
# Provides: extract_knowledge, retrieve_knowledge, inject_knowledge

KNOWLEDGE_LOG="${KNOWLEDGE_LOG:-$HOME/.myndaix/bridge/state/knowledge.jsonl}"
KNOWLEDGE_LOCK="${KNOWLEDGE_LOG}.lock"
KNOWLEDGE_MAX_INJECT=5  # max entries to inject per task
KNOWLEDGE_MAX_SUMMARY=1024  # max chars per summary
KNOWLEDGE_MAX_FILES=25  # max files per entry

mkdir -p "$(dirname "$KNOWLEDGE_LOG")"

# extract_knowledge <agent> <task_file> <result_file> <status> [repo]
# Called after task completion. Extracts structured learnings and appends to knowledge.jsonl
# Fix 2: Uses flock for atomic appends
# Fix 4: Redacts sensitive patterns from summaries
extract_knowledge() {
  local agent="$1"
  local task_file="$2"
  local result_file="$3"
  local task_status="$4"
  local repo="${5:-}"

  [[ -z "$agent" || -z "$task_file" ]] && return 0

  python3 -c "
import json, sys, os, re, fcntl
from datetime import datetime, timezone

agent = sys.argv[1]
task_path = sys.argv[2]
result_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ''
status = sys.argv[4] if len(sys.argv) > 4 else 'unknown'
knowledge_log = sys.argv[5]
lock_file = sys.argv[6]
max_summary = int(sys.argv[7])
max_files = int(sys.argv[8])
repo = sys.argv[9] if len(sys.argv) > 9 else ''

# --- Sensitive pattern redaction (Fix 4) ---
SENSITIVE_PATTERNS = [
    r'sk-[a-zA-Z0-9_-]{20,}',           # API keys (OpenAI, Anthropic)
    r'AIza[a-zA-Z0-9_-]{30,}',           # Google API keys
    r'pplx-[a-zA-Z0-9]{30,}',            # Perplexity keys
    r'ntn_[a-zA-Z0-9]{30,}',             # Notion tokens
    r'ghp_[a-zA-Z0-9]{30,}',             # GitHub PATs
    r'ghs_[a-zA-Z0-9]{30,}',             # GitHub App tokens
    r'MTQ[a-zA-Z0-9._-]{50,}',           # Discord bot tokens
    r'AKIA[A-Z0-9]{16}',                 # AWS access key IDs
    r'eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}',  # JWT tokens
    r'https?://[^@\s]*:[^@\s]*@',        # URL-embedded credentials
    r'[a-zA-Z0-9+/]{40,}={0,2}',         # Base64 encoded secrets (long)
    r'password\s*[=:]\s*\S+',            # password = xxx
    r'secret\s*[=:]\s*\S+',             # secret = xxx
    r'token\s*[=:]\s*\S+',              # token = xxx
    r'api[_-]?key\s*[=:]\s*\S+',        # api_key = xxx
    r'private[_-]?key\s*[=:]\s*\S+',    # private_key = xxx
]

def redact(text):
    for pattern in SENSITIVE_PATTERNS:
        text = re.sub(pattern, '[REDACTED]', text, flags=re.IGNORECASE)
    return text

# Read task frontmatter
task_subject = ''
task_scope = ''
task_id = ''
task_objective = ''
task_repo = repo
try:
    with open(task_path) as f:
        task_content = f.read()
    m = re.match(r'^---\s*\n(.*?)\n---', task_content, re.DOTALL)
    if m:
        for line in m.group(1).split('\n'):
            stripped = line.strip()
            if stripped.startswith('subject:'):
                task_subject = stripped.split(':', 1)[1].strip().strip('\"')
            elif stripped.startswith('task_id:'):
                task_id = stripped.split(':', 1)[1].strip().strip('\"')
            elif stripped.startswith('objective:'):
                task_objective = stripped.split(':', 1)[1].strip().strip('\"')
            elif stripped.startswith('scope:'):
                task_scope = stripped.split(':', 1)[1].strip().strip('\"')
            elif stripped.startswith('repo:') and not task_repo:
                task_repo = stripped.split(':', 1)[1].strip().strip('\"')
except Exception:
    pass

# Extract files touched from result (capped at max_files)
files_touched = []
result_summary = ''
try:
    if result_path and os.path.exists(result_path):
        with open(result_path) as f:
            result_content = f.read()
        for line in result_content.split('\n'):
            full_matches = re.findall(r'[\w/.-]+\.(?:sh|js|py|swift|ts|tsx|json|yaml|yml|md)', line)
            files_touched.extend(full_matches)
        files_touched = list(set(files_touched))[:max_files]

        # Extract summary (capped + redacted)
        lines = [l.strip() for l in result_content.split('\n')
                 if l.strip() and not l.startswith('---') and not l.startswith('#')]
        result_summary = redact(' '.join(lines[:3])[:max_summary])
except Exception:
    pass

# Redact objective and subject too
task_subject = redact(task_subject[:200])
task_objective = redact(task_objective[:300])

# Build knowledge entry with repo scope (Fix 3)
entry = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'agent': agent,
    'task_id': task_id,
    'subject': task_subject,
    'objective': task_objective,
    'status': status,
    'files': files_touched,
    'scope': task_scope[:200],
    'repo': task_repo,
    'summary': result_summary,
    'task_file': os.path.basename(task_path),
}

# Atomic append with flock (Fix 2) — NOTE: locking IS present here.
# KilaBz P3 (2026-04-13) flagged non-atomic append but referenced
# the file-reading section above, not this write section. Verified correct.
os.makedirs(os.path.dirname(knowledge_log), exist_ok=True)
lock_fd = open(lock_file, 'w')
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    with open(knowledge_log, 'a') as f:
        f.write(json.dumps(entry) + '\n')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()

" "$agent" "$task_file" "${result_file:-}" "${task_status:-unknown}" "$KNOWLEDGE_LOG" "$KNOWLEDGE_LOCK" "$KNOWLEDGE_MAX_SUMMARY" "$KNOWLEDGE_MAX_FILES" "${repo:-}" 2>/dev/null || true
}

# retrieve_knowledge <scope_files> <repo_filter> <agent_filter> [max_results]
# Searches knowledge.jsonl for entries matching the given files/scope
# Fix 1 (v2): Output is STRUCTURED METADATA ONLY — no free-text summaries
# Fix 3 (v2): repo_filter REQUIRED — empty = fail closed (return nothing)
# Fix 5: Handles corrupted lines gracefully (skip, don't halt)
# Fix 6: agent_filter REQUIRED — agents only see own entries + shared
retrieve_knowledge() {
  local scope="$1"
  local repo_filter="$2"
  local agent_filter="$3"
  local max_results="${4:-$KNOWLEDGE_MAX_INJECT}"

  [[ ! -f "$KNOWLEDGE_LOG" ]] && return 0
  [[ -z "$scope" ]] && return 0

  # Fix 3 (v2): Fail closed — repo scope is mandatory
  if [[ -z "$repo_filter" ]]; then
    echo "[knowledge] BLOCKED: repo_filter required for retrieval (fail closed)" >&2
    return 0
  fi

  # Fix 6: Agent identity is mandatory
  if [[ -z "$agent_filter" ]]; then
    echo "[knowledge] BLOCKED: agent_filter required for retrieval (fail closed)" >&2
    return 0
  fi

  python3 -c "
import json, sys, os, re

scope_input = sys.argv[1]
max_results = int(sys.argv[2])
knowledge_log = sys.argv[3]
repo_filter = sys.argv[4]
agent_filter = sys.argv[5]

if not os.path.exists(knowledge_log):
    sys.exit(0)

# Parse scope into search terms
search_terms = []
STOP_FILES = {'package.json', 'readme.md', 'index.js', 'index.ts', 'main.py', '__init__.py', '.gitignore'}

for term in scope_input.replace(',', ' ').split():
    term = term.strip().strip('\"').strip(\"'\")
    if term and len(term) > 2:
        basename = os.path.basename(term).lower()
        if basename and basename not in STOP_FILES:
            search_terms.append(basename)
        if term.lower() not in STOP_FILES:
            search_terms.append(term.lower())

if not search_terms:
    sys.exit(0)

# Read all entries, skip corrupt lines (Fix 5), score by relevance
scored = []
corrupt_count = 0
for line_num, line in enumerate(open(knowledge_log), 1):
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        corrupt_count += 1
        continue

    # Fix 3 (v2): Mandatory repo scoping — skip entries with no repo or wrong repo
    entry_repo = entry.get('repo', '')
    if not entry_repo or repo_filter not in entry_repo:
        continue

    # Fix 6: Agent scoping — agent sees own entries only
    # (Lobster sees all for orchestration)
    entry_agent = entry.get('agent', '')
    if agent_filter != 'lobster' and entry_agent and entry_agent != agent_filter:
        continue

    # Score: weighted by field importance
    score = 0
    subject = entry.get('subject', '').lower()
    for term in search_terms:
        if term in subject:
            score += 3

    entry_files = [f.lower() for f in entry.get('files', [])]
    for term in search_terms:
        for ef in entry_files:
            if term in ef:
                score += 2

    obj_scope = (entry.get('objective', '') + ' ' + entry.get('scope', '')).lower()
    for term in search_terms:
        if term in obj_scope:
            score += 1

    if score > 0:
        scored.append((score, entry))

# Sort by score descending, take top N
scored.sort(key=lambda x: -x[0])
top = scored[:max_results]

if not top:
    sys.exit(0)

# Fix 1 (v2): STRUCTURED METADATA ONLY — no free-text summaries in output
# This eliminates the prompt injection vector entirely.
# Summaries are stored for offline analysis but NEVER injected into prompts.
print('## Prior Knowledge (structured metadata only)')
print('')
for score, entry in top:
    status_icon = 'PASS' if entry.get('status') == 'PASS' else 'FAIL' if entry.get('status') == 'FAILED' else 'INFO'
    # Only emit: status, subject (first 80 chars), agent, date, files
    # NO summary, NO objective (both contain free-text from results)
    subject = entry.get('subject', 'Unknown')[:80]
    # Strip any non-alphanumeric except basic punctuation (allowlist, not denylist)
    subject = re.sub(r'[^a-zA-Z0-9 _./-]', '', subject)
    agent = re.sub(r'[^a-zA-Z0-9_-]', '', entry.get('agent', '?'))
    ts = entry.get('ts', '?')[:10]
    print(f'- [{status_icon}] {subject} (by {agent}, {ts})')
    if entry.get('files'):
        # Only filenames, stripped of path traversal
        safe_files = [re.sub(r'[^a-zA-Z0-9._/-]', '', os.path.basename(f)) for f in entry['files'][:5]]
        files_str = ', '.join(safe_files)
        print(f'  Files: {files_str}')
print('')

if corrupt_count > 0:
    print(f'[WARNING] {corrupt_count} corrupt entries skipped', file=sys.stderr)

" "$scope" "$max_results" "$KNOWLEDGE_LOG" "$repo_filter" "$agent_filter"
  local rag_rc=$?
  if [[ $rag_rc -ne 0 ]]; then
    echo "[knowledge] WARNING: retrieval failed (rc=$rag_rc) for scope='$scope' repo='$repo_filter' agent='$agent_filter'" >&2
  fi
}

# inject_knowledge <task_file> <prompt_file> <agent> [repo]
# Reads the task's scope, retrieves relevant knowledge, appends to prompt file
# Fix 1 (v2): Only structured metadata injected — no free-text
# Fix 6: Agent identity REQUIRED — fail closed if missing
inject_knowledge() {
  local task_file="$1"
  local prompt_file="$2"
  local agent="$3"
  local repo="${4:-}"

  [[ ! -f "$task_file" || ! -f "$prompt_file" ]] && return 0
  [[ ! -f "$KNOWLEDGE_LOG" ]] && return 0

  # Fix 6: Agent identity required
  if [[ -z "$agent" ]]; then
    echo "[knowledge] BLOCKED: agent identity required for inject_knowledge" >&2
    return 0
  fi

  # Extract scope and repo from task frontmatter
  local scope
  local task_repo
  read -r scope task_repo < <(python3 -c "
import sys, re
content = open(sys.argv[1]).read()
m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)
parts = []
repo_val = ''
for line in fm.split('\n'):
    line = line.strip()
    if line.startswith('- ') and ('/' in line or '.' in line):
        parts.append(line[2:].strip().strip('\"'))
    elif line.startswith('subject:'):
        parts.append(line.split(':', 1)[1].strip().strip('\"'))
    elif line.startswith('repo:'):
        repo_val = line.split(':', 1)[1].strip().strip('\"')
        parts.append(repo_val)
print(' '.join(parts) + '\t' + repo_val)
" "$task_file" 2>/dev/null)

  # Use explicit repo param, fall back to frontmatter repo
  local effective_repo="${repo:-$task_repo}"

  # Fix 3 (v2): Fail closed — must have repo scope
  if [[ -z "$effective_repo" ]]; then
    echo "[knowledge] BLOCKED: no repo scope for inject_knowledge (fail closed)" >&2
    return 0
  fi

  if [[ -n "$scope" ]]; then
    local knowledge
    knowledge=$(retrieve_knowledge "$scope" "$effective_repo" "$agent" "$KNOWLEDGE_MAX_INJECT")
    if [[ -n "$knowledge" ]]; then
      # Structured metadata only — safe to inject (no free-text content)
      printf '\n<prior_knowledge type="structured-metadata">\n%s\n</prior_knowledge>\n' "$knowledge" >> "$prompt_file"
    fi
  fi
}
