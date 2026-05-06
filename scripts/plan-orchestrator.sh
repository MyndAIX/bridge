#!/usr/bin/env bash
#
# plan-orchestrator.sh — The conductor. Runs on heartbeat to advance active plans.
#
# What it does:
#   1. Lists all active plans
#   2. Checks completions against each plan (marks tasks done)
#   3. Dispatches next wave of ready tasks
#   4. Returns a summary for Lobster to post to #command-center
#
# Usage:
#   bash ~/.myndaix/bridge/scripts/plan-orchestrator.sh
#   bash ~/.myndaix/bridge/scripts/plan-orchestrator.sh --plan MX-PLAN-001
#   bash ~/.myndaix/bridge/scripts/plan-orchestrator.sh --dry-run
#

set -uo pipefail

BRIDGE_DIR="${HOME}/.myndaix/bridge"
SCRIPTS_DIR="${BRIDGE_DIR}/scripts"
PLAN_ENGINE="${SCRIPTS_DIR}/plan-engine.sh"
LOG="/tmp/plan-orchestrator.log"

# Source the plan engine
if [[ ! -f "$PLAN_ENGINE" ]]; then
  echo "ERROR: plan-engine.sh not found at $PLAN_ENGINE" >&2
  exit 1
fi
source "$PLAN_ENGINE"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Parse args
DRY_RUN=false
SPECIFIC_PLAN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --plan) SPECIFIC_PLAN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Main orchestration loop ──

output=""
total_dispatched=0
plans_checked=0
plans_progressed=0

if [[ -n "$SPECIFIC_PLAN" ]]; then
  active_plans="$SPECIFIC_PLAN"
else
  active_plans=$(list_active_plans 2>/dev/null | awk -F' \\| ' '{print $1}' | tr -d ' ')
fi

if [[ -z "$active_plans" ]]; then
  echo "NO_ACTIVE_PLANS"
  exit 0
fi

while IFS= read -r plan_id; do
  [[ -z "$plan_id" ]] && continue
  plans_checked=$((plans_checked + 1))
  log "Checking plan: $plan_id"

  # Step 1: Check completions against plan
  progress_json=$(check_plan_progress "$plan_id" 2>/dev/null)
  if [[ -z "$progress_json" ]]; then
    log "WARNING: No progress data for $plan_id"
    continue
  fi

  changed=$(echo "$progress_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('changed', False))")
  status=$(echo "$progress_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status', 'unknown'))")
  done_count=$(echo "$progress_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('done', 0))")
  total_count=$(echo "$progress_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total', 0))")
  in_progress=$(echo "$progress_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('in_progress', 0))")
  pending=$(echo "$progress_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pending', 0))")
  failed=$(echo "$progress_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('failed', 0))")
  ready_tasks=$(echo "$progress_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(d.get('ready_to_dispatch', [])))")

  if [[ "$changed" == "True" ]]; then
    plans_progressed=$((plans_progressed + 1))
    log "Plan $plan_id progressed: $done_count/$total_count done"
  fi

  # Step 2: Dispatch next wave (if there are ready tasks)
  wave_dispatched=0
  if [[ -n "$ready_tasks" && "$ready_tasks" != "" && "$status" == "active" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: Would dispatch wave for $plan_id: $ready_tasks"
      wave_dispatched=$(echo "$ready_tasks" | wc -w | tr -d ' ')
    else
      wave_dispatched=$(dispatch_wave "$plan_id" 2>/dev/null)
      [[ -z "$wave_dispatched" ]] && wave_dispatched=0
      log "Dispatched $wave_dispatched tasks for plan $plan_id"
    fi
    total_dispatched=$((total_dispatched + wave_dispatched))
  fi

  # Step 3: Check if plan just completed
  if [[ "$status" == "complete" ]]; then
    output="${output}**${plan_id}** — COMPLETE ($done_count/$total_count tasks passed)\n"
  elif [[ "$status" == "complete_with_failures" ]]; then
    output="${output}**${plan_id}** — COMPLETE WITH FAILURES ($done_count done, $failed failed)\n"
  else
    output="${output}**${plan_id}** — ${done_count}/${total_count} done"
    [[ "$in_progress" -gt 0 ]] && output="${output}, ${in_progress} in flight"
    [[ "$wave_dispatched" -gt 0 ]] && output="${output}, dispatched ${wave_dispatched} new"
    [[ "$pending" -gt 0 && "$wave_dispatched" -eq 0 && "$in_progress" -eq 0 ]] && output="${output}, ${pending} blocked"
    output="${output}\n"
  fi

done <<< "$active_plans"

# ── Output summary ──

if [[ "$plans_checked" -eq 0 ]]; then
  echo "NO_ACTIVE_PLANS"
  exit 0
fi

echo -e "$output"

if [[ "$total_dispatched" -gt 0 ]]; then
  log "Total dispatched this cycle: $total_dispatched"
fi

exit 0
