#!/bin/bash
# review-pipeline.sh — MyndAIX Three-Model Review Pipeline
# Runs KilaBz (Codex) + Oracle (Gemini) in parallel on code files
# Usage: review-pipeline.sh <file1> [file2] ... [-m "review focus message"]
#
# Called by: Mack (via /feature), Lobster (via Discord dispatch), Mini (via auto-review)

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

LOG="$HOME/.myndaix/bridge/watchers/review-pipeline.log"
DISPATCH="$HOME/.myndaix/bridge/inbox/dispatch"
RESULTS_DIR="$HOME/.myndaix/bridge/state/reviews"
ALERT_WEBHOOK="$(grep DISCORD_WEBHOOK_MACK "$HOME/.myndaix/discord/.env" 2>/dev/null | cut -d= -f2-)"

mkdir -p "$RESULTS_DIR" "$DISPATCH" "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [review] $*" >> "$LOG"; }

# Parse args
FILES=()
MESSAGE="Review this code for bugs, security issues, edge cases, and reliability."
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message) MESSAGE="$2"; shift 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "Usage: review-pipeline.sh <file1> [file2] ... [-m \"focus message\"]"
  exit 1
fi

REVIEW_ID="RV-$(date -u '+%Y%m%d-%H%M%S')"
log "Starting review $REVIEW_ID: ${#FILES[@]} files"

# Build code content block
CODE_BLOCK=""
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then
    CODE_BLOCK="$CODE_BLOCK
### File: $f
\`\`\`
$(cat "$f")
\`\`\`
"
    log "  Including: $f ($(wc -l < "$f" | tr -d ' ') lines)"
  else
    log "  SKIP: $f (not found)"
  fi
done

if [ -z "$CODE_BLOCK" ]; then
  echo "No valid files found."
  exit 1
fi

echo "🔍 Review $REVIEW_ID — ${#FILES[@]} files"
echo "   KilaBz (Codex) + Oracle (Gemini) running in parallel..."

# ═══ ROUND 1: KilaBz + Oracle in parallel ═══

# KilaBz via dispatch
KILABZ_TASK="$DISPATCH/${REVIEW_ID}-kilabz-review.md"
cat > "$KILABZ_TASK" << KILABZEOF
---
from: mack
type: review
subject: "Review $REVIEW_ID — ${#FILES[@]} files"
objective: $MESSAGE
scope: $(echo "${FILES[@]}" | tr ' ' ', ')
done_criteria: Findings with severity (P0-P3), file:line references, and recommendations
priority: P1 — High
repo: ${DEFAULT_REPO:-$HOME/.openclaw/workspace}
branch: main
tier: auto
task_id: $REVIEW_ID
---

# Code Review: $REVIEW_ID

$MESSAGE

$CODE_BLOCK

Write findings to ~/.myndaix/bridge/inbox/lobster/${REVIEW_ID}-kilabz-findings.md with type: result.
KILABZEOF
log "  Dispatched to KilaBz via auto-router"

# Oracle via gemini CLI (runs in background)
ORACLE_RESULT="$RESULTS_DIR/${REVIEW_ID}-oracle.md"
ORACLE_PROMPT="You are Oracle, MyndAIX's third-eye reviewer powered by Gemini. Review this code for issues that Claude and Codex reviewers might miss. Focus on: reliability under real-world conditions, edge cases, alternative approaches, and architectural concerns. Be specific with file references.

$MESSAGE

$CODE_BLOCK"

# Try pro first, fall back to flash
(
  RESULT=$(gemini -m gemini-3.1-pro-preview -p "$ORACLE_PROMPT" 2>/dev/null)
  if [ -z "$RESULT" ] || echo "$RESULT" | grep -q "Error\|error"; then
    RESULT=$(gemini -m gemini-2.5-flash -p "$ORACLE_PROMPT" 2>/dev/null)
    [ -n "$RESULT" ] && echo "(Oracle fell back to Flash)" >> "$LOG"
  fi
  echo "$RESULT" > "$ORACLE_RESULT"
  log "  Oracle review complete: $(wc -l < "$ORACLE_RESULT" | tr -d ' ') lines"
) &
ORACLE_PID=$!

echo "   ⏳ Waiting for Oracle (Gemini)..."
wait $ORACLE_PID 2>/dev/null

# Check Oracle result
if [ -f "$ORACLE_RESULT" ] && [ -s "$ORACLE_RESULT" ]; then
  echo "   ✅ Oracle: done"
else
  echo "   ⚠️  Oracle: no response"
  echo "(Oracle returned empty response)" > "$ORACLE_RESULT"
fi

echo "   ⏳ Waiting for KilaBz (dispatched via auto-router)..."
echo ""

# Wait for KilaBz (check every 10s for up to 5 min)
KILABZ_RESULT=""
for i in $(seq 1 30); do
  # Check for result in lobster inbox or processed
  for f in "$HOME/.myndaix/bridge/inbox/lobster/${REVIEW_ID}"*.md "$HOME/.myndaix/bridge/processed/${REVIEW_ID}"*.md; do
    if [ -f "$f" ] && grep -q "kilabz" "$f" 2>/dev/null; then
      KILABZ_RESULT="$f"
      break 2
    fi
  done
  sleep 10
done

if [ -n "$KILABZ_RESULT" ]; then
  echo "   ✅ KilaBz: done"
else
  echo "   ⚠️  KilaBz: timeout (5 min) — check inbox/lobster/ manually"
fi

# ═══ SYNTHESIS ═══

SYNTHESIS="$RESULTS_DIR/${REVIEW_ID}-synthesis.md"
cat > "$SYNTHESIS" << SYNTHEOF
# Review $REVIEW_ID — Three-Model Synthesis

**Files:** $(echo "${FILES[@]}" | tr ' ' ', ')
**Focus:** $MESSAGE
**Date:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')

---

## Oracle (Gemini) Findings

$(cat "$ORACLE_RESULT")

---

## KilaBz (Codex) Findings

$(if [ -n "$KILABZ_RESULT" ]; then cat "$KILABZ_RESULT"; else echo "(Pending — check inbox/lobster/)"; fi)

---

## Next Steps

1. Mack synthesizes both reviews (agree / push back / scope down)
2. Fix P1s, commit separately
3. KilaBz re-reviews fixes
4. Merge when all P1s confirmed resolved

**Review ID:** $REVIEW_ID
SYNTHEOF

echo ""
echo "═══════════════════════════════════════"
echo "  Review $REVIEW_ID complete"
echo "  Synthesis: $SYNTHESIS"
echo "═══════════════════════════════════════"

# Post to Discord
if [ -n "$ALERT_WEBHOOK" ]; then
  curl -s -H 'Content-Type: application/json' \
    -d "{\"content\": \"🔍 **Review $REVIEW_ID** — KilaBz + Oracle completed. Synthesis at: $SYNTHESIS\"}" \
    "$ALERT_WEBHOOK" > /dev/null 2>&1
fi

log "Review $REVIEW_ID complete. Synthesis: $SYNTHESIS"
