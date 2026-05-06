#!/usr/bin/env bash
#
# drain-completions.sh — Heartbeat completion drain for the auto-loop.
#
# Phase 2 closer: reads completion signals, advances plans, reports status.
# Called by Lobster's heartbeat (or manually).
#
# What it does:
#   1. Reads all unprocessed completion signals from state/completions/
#   2. Runs plan-orchestrator to advance any active plans
#   3. Groups remaining (non-plan) completions and summarizes
#   4. Archives processed completions to state/completions/processed/
#   5. Outputs a summary for Lobster to post
#
# Usage:
#   bash drain-completions.sh           # normal run
#   bash drain-completions.sh --dry-run # report only, don't archive
#

set -uo pipefail

BRIDGE_DIR="${HOME}/.myndaix/bridge"
COMPLETIONS_DIR="${BRIDGE_DIR}/state/completions"
PROCESSED_DIR="${COMPLETIONS_DIR}/processed"
ORCHESTRATOR="${BRIDGE_DIR}/scripts/plan-orchestrator.sh"
MARKER="${BRIDGE_DIR}/state/completions-last-drain.marker"

mkdir -p "$COMPLETIONS_DIR" "$PROCESSED_DIR"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Step 1: Count new completions since last drain ──
new_count=0
new_files=()

for f in "$COMPLETIONS_DIR"/*.md; do
  [[ -f "$f" ]] || continue
  if [[ -f "$MARKER" ]]; then
    # Only process files newer than the marker
    if [[ "$f" -nt "$MARKER" ]]; then
      new_files+=("$f")
      new_count=$((new_count + 1))
    fi
  else
    new_files+=("$f")
    new_count=$((new_count + 1))
  fi
done

if [[ "$new_count" -eq 0 ]]; then
  echo "NO_NEW_COMPLETIONS"
  exit 0
fi

# ── Step 2: Run plan orchestrator (advances plans, dispatches waves) ──
plan_output=""
if [[ -x "$ORCHESTRATOR" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    plan_output=$(bash "$ORCHESTRATOR" --dry-run 2>/dev/null)
  else
    plan_output=$(bash "$ORCHESTRATOR" 2>/dev/null)
  fi
fi

# ── Step 3: Summarize new completions ──
summary=$(python3 - "${new_files[@]}" <<'PYEOF'
import sys, os, re

files = sys.argv[1:]
entries = []

for fpath in files:
    try:
        content = open(fpath).read()
    except Exception:
        continue
    m = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if not m:
        continue
    fm = {}
    for line in m.group(1).split("\n"):
        if ":" in line:
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    entries.append({
        "agent": fm.get("agent", "?"),
        "task_id": fm.get("task_id", "?"),
        "result": fm.get("result", "?"),
        "completed": fm.get("completed", "?"),
        "file": os.path.basename(fpath)
    })

passed = [e for e in entries if e["result"] == "PASS"]
failed = [e for e in entries if e["result"] != "PASS"]

parts = []
if passed:
    parts.append(f"✅ {len(passed)} PASS")
if failed:
    parts.append(f"❌ {len(failed)} FAIL")

sep = " | "
print(f"**Completions:** {sep.join(parts)} ({len(entries)} total)")

for e in entries:
    icon = "✅" if e["result"] == "PASS" else "❌"
    agent = e["agent"]
    task = e["task_id"]
    result = e["result"]
    print(f"  {icon} [{agent}] {task} — {result}")
PYEOF
)

# ── Step 3.4: Run conversation orchestrator (auto-advance thread rounds) ──
CONV_ORCH="${BRIDGE_DIR}/scripts/conversation-orchestrator.sh"
conv_output=""
if [[ -x "$CONV_ORCH" ]]; then
  conv_output=$(bash "$CONV_ORCH" --scan 2>/dev/null || true)
fi

# ── Step 3.5: Run completion scanner (dispatches Oracle auto-reviews) ──
# Must run BEFORE archiving — scanner reads from active completions dir
SCANNER="${BRIDGE_DIR}/scripts/completion-scanner.sh"
scanner_output=""
if [[ -f "$SCANNER" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    scanner_output=$(bash "$SCANNER" --dry-run 2>/dev/null || true)
  else
    scanner_output=$(bash "$SCANNER" 2>/dev/null || true)
  fi
fi

# ── Step 4: Archive processed completions ──
if [[ "$DRY_RUN" == "false" ]]; then
  for f in "${new_files[@]}"; do
    mv "$f" "$PROCESSED_DIR/" 2>/dev/null || true
  done
  # Update marker
  touch "$MARKER"
fi

# ── Step 5: Output ──
echo "$summary"
if [[ -n "$conv_output" && "$conv_output" != "NO_THREAD_RESULTS" ]]; then
  echo ""
  echo "**Threads:** $conv_output"
fi
if [[ -n "$scanner_output" && "$scanner_output" != "NO_NEW_COMPLETIONS" ]]; then
  echo ""
  echo "**Auto-reviews:** $scanner_output"
fi
if [[ -n "$plan_output" && "$plan_output" != "NO_ACTIVE_PLANS" ]]; then
  echo ""
  echo "**Plans:**"
  echo "$plan_output"
fi
