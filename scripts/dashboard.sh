#!/usr/bin/env bash
set -euo pipefail
command -v sqlite3 >/dev/null || { echo "ERROR: sqlite3 required" >&2; exit 1; }
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DB="${MYNDAIX_MEMORY_DB:-$HOME/.myndaix/memory.db}"

if [[ ! -f "$DB" ]]; then
  echo "ERROR: memory.db not found at $DB"
  exit 1
fi

sql() { sqlite3 -separator '|' "$DB" "$1"; }

BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
RESET=$'\033[0m'

header() {
  echo ""
  echo "${BOLD}${CYAN}━━━ $1 ━━━${RESET}"
  echo ""
}

# ── SECTION 1: Active Work ──────────────────────────────────────────

header "ACTIVE WORK"

active=$(sql "
  SELECT id, agent, type, priority,
         CASE WHEN LENGTH(objective) > 60 THEN SUBSTR(objective, 1, 57) || '...' ELSE COALESCE(objective, '') END,
         status,
         CAST((julianday('now') - julianday(dispatched_at)) * 24 AS INTEGER) || 'h'
  FROM tasks
  WHERE status IN ('queued', 'claimed', 'in-progress')
  ORDER BY priority ASC, dispatched_at ASC;
")

if [[ -z "$active" ]]; then
  echo "  ${DIM}No active work${RESET}"
else
  printf "  ${BOLD}%-28s %-10s %-10s %-4s %-62s %-12s %s${RESET}\n" \
    "ID" "AGENT" "TYPE" "PRI" "OBJECTIVE" "STATUS" "AGE"
  echo "  $(printf '%.0s─' {1..140})"
  while IFS='|' read -r id agent type pri obj status age; do
    printf "  %-28s %-10s %-10s %-4s %-62s %-12s %s\n" \
      "$id" "$agent" "$type" "$pri" "$obj" "$status" "$age"
  done <<< "$active"
fi

# ── SECTION 2: Recent Completions (24h) ─────────────────────────────

header "RECENT COMPLETIONS (24h)"

recent=$(sql "
  SELECT id, agent, status,
         CASE WHEN completed_at IS NOT NULL AND dispatched_at IS NOT NULL
              THEN CAST((julianday(completed_at) - julianday(dispatched_at)) * 24 * 60 AS INTEGER) || 'm'
              ELSE '—' END,
         CASE WHEN LENGTH(objective) > 60 THEN SUBSTR(objective, 1, 57) || '...' ELSE COALESCE(objective, '') END
  FROM tasks
  WHERE status IN ('completed', 'failed')
    AND completed_at >= datetime('now', '-24 hours')
  ORDER BY completed_at DESC;
")

if [[ -z "$recent" ]]; then
  echo "  ${DIM}No completions in last 24h${RESET}"
else
  printf "  ${BOLD}%-28s %-10s %-10s %-8s %s${RESET}\n" \
    "ID" "AGENT" "STATUS" "DURATION" "OBJECTIVE"
  echo "  $(printf '%.0s─' {1..120})"
  while IFS='|' read -r id agent status dur obj; do
    color="$RESET"
    [[ "$status" == "failed" ]] && color="$RED"
    [[ "$status" == "completed" ]] && color="$GREEN"
    printf "  ${color}%-28s %-10s %-10s %-8s %s${RESET}\n" \
      "$id" "$agent" "$status" "$dur" "$obj"
  done <<< "$recent"
fi

# ── SECTION 3: Agent Status ─────────────────────────────────────────

header "AGENT STATUS"

agents=$(sql "
  SELECT DISTINCT agent FROM tasks ORDER BY agent;
")

if [[ -z "$agents" ]]; then
  echo "  ${DIM}No agents have processed tasks${RESET}"
else
  printf "  ${BOLD}%-12s %10s %10s %-30s %s${RESET}\n" \
    "AGENT" "DONE/24h" "FAIL/24h" "CURRENT TASK" "NOTE"
  echo "  $(printf '%.0s─' {1..90})"
  while IFS= read -r agent; do
    done_count=$(sql "SELECT COUNT(*) FROM tasks WHERE agent='$agent' AND status='completed' AND completed_at >= datetime('now', '-24 hours');")
    fail_count=$(sql "SELECT COUNT(*) FROM tasks WHERE agent='$agent' AND status='failed' AND completed_at >= datetime('now', '-24 hours');")
    current=$(sql "SELECT CASE WHEN LENGTH(objective) > 28 THEN SUBSTR(objective, 1, 25) || '...' ELSE COALESCE(objective, id) END FROM tasks WHERE agent='$agent' AND status IN ('claimed', 'in-progress') LIMIT 1;")
    [[ -z "$current" ]] && current="—"
    note=""
    total=$((done_count + fail_count))
    if [[ $total -gt 0 && $fail_count -gt 0 ]]; then
      rate=$(( (fail_count * 100) / total ))
      [[ $rate -gt 50 ]] && note="${RED}⚠ ${rate}% failure rate${RESET}"
    fi
    # Note: no heartbeat data in schema — column omitted
    printf "  %-12s %10s %10s %-30s %s\n" \
      "$agent" "$done_count" "$fail_count" "$current" "$note"
  done <<< "$agents"
fi

# ── SECTION 4: Queue Depth ──────────────────────────────────────────

header "QUEUE DEPTH"

queue=$(sql "
  SELECT agent, COUNT(*) FROM tasks
  WHERE status = 'queued'
  GROUP BY agent
  ORDER BY COUNT(*) DESC;
")

if [[ -z "$queue" ]]; then
  echo "  ${DIM}Queue empty${RESET}"
else
  total_queued=$(sql "SELECT COUNT(*) FROM tasks WHERE status='queued';")
  printf "  ${BOLD}%-12s %s${RESET}\n" "AGENT" "QUEUED"
  echo "  $(printf '%.0s─' {1..25})"
  while IFS='|' read -r agent count; do
    printf "  %-12s %s\n" "$agent" "$count"
  done <<< "$queue"
  echo ""
  echo "  ${BOLD}Total queued: ${total_queued}${RESET}"
fi

# ── SECTION 5: Dead Letters ─────────────────────────────────────────

header "DEAD LETTERS"

dead=$(sql "
  SELECT id, agent,
         CASE WHEN LENGTH(COALESCE(error, '')) > 50 THEN SUBSTR(error, 1, 47) || '...' ELSE COALESCE(error, '—') END,
         completed_at
  FROM tasks
  WHERE status = 'failed' AND retry_count >= max_retries
  ORDER BY completed_at DESC
  LIMIT 20;
")

if [[ -z "$dead" ]]; then
  echo "  ${DIM}No dead letters${RESET}"
else
  printf "  ${BOLD}%-28s %-10s %-52s %s${RESET}\n" \
    "ID" "AGENT" "ERROR" "DIED AT"
  echo "  $(printf '%.0s─' {1..100})"
  while IFS='|' read -r id agent err died; do
    printf "  ${RED}%-28s %-10s %-52s %s${RESET}\n" \
      "$id" "$agent" "$err" "$died"
  done <<< "$dead"
fi

# ── SECTION 6: Pattern Proposals ────────────────────────────────────

header "PATTERN PROPOSALS"

proposals=$(sql "
  SELECT fingerprint, description, occurrences, COALESCE(recommended_type, pattern_type)
  FROM patterns
  WHERE occurrences >= 3 AND promoted = 0 AND rejected = 0
  ORDER BY occurrences DESC;
")

if [[ -z "$proposals" ]]; then
  echo "  ${DIM}No pending pattern proposals${RESET}"
else
  printf "  ${BOLD}%-20s %-50s %6s %s${RESET}\n" \
    "FINGERPRINT" "DESCRIPTION" "COUNT" "RECOMMENDED"
  echo "  $(printf '%.0s─' {1..90})"
  while IFS='|' read -r fp desc count rec; do
    printf "  ${YELLOW}%-20s %-50s %6s %s${RESET}\n" \
      "$fp" "$desc" "$count" "$rec"
  done <<< "$proposals"
fi

echo ""
echo "${DIM}─── dashboard sourced from ${DB} at $(date '+%Y-%m-%d %H:%M:%S') ───${RESET}"
echo ""
echo "# Add to .zshrc: alias factory='bash ~/.myndaix/scripts/dashboard.sh'"
