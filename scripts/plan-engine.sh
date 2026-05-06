#!/usr/bin/env bash
#
# plan-engine.sh — Task decomposition and wave-based dispatch for MyndAIX
#
# Phase 3 of 10x Production Plan. Lobster calls these functions to:
#   1. Create a plan from a task graph (create_plan)
#   2. Dispatch the next wave of ready tasks (dispatch_wave)
#   3. Check plan progress against completions (check_plan_progress)
#   4. Mark a plan task as done (mark_plan_task_done)
#
# Plan format: JSON file in state/plans/{plan_id}.json
#
# Usage: source this file, then call functions directly.
#

set -uo pipefail

BRIDGE_DIR="${HOME}/.myndaix/bridge"
PLANS_DIR="${BRIDGE_DIR}/state/plans"
COMPLETIONS_DIR="${BRIDGE_DIR}/state/completions"
DISPATCH_SCRIPT="${BRIDGE_DIR}/dispatch.sh"

mkdir -p "$PLANS_DIR"

# ── create_plan ──
# Creates a new plan JSON file from arguments.
# Args: PLAN_ID OBJECTIVE STATUS
# Plan tasks are added separately via add_plan_task.
# Writes: state/plans/{plan_id}.json
create_plan() {
  local plan_id="$1"
  local objective="$2"
  local status="${3:-pending_approval}"

  local plan_file="${PLANS_DIR}/${plan_id}.json"

  python3 -c '
import json, sys
from datetime import datetime, timezone

plan = {
    "plan_id": sys.argv[1],
    "objective": sys.argv[2],
    "status": sys.argv[3],
    "created": datetime.now(timezone.utc).isoformat(),
    "updated": datetime.now(timezone.utc).isoformat(),
    "tasks": [],
    "max_retries": 3,
    "retry_counts": {}
}
with open(sys.argv[4], "w") as f:
    json.dump(plan, f, indent=2)
print(sys.argv[4])
' "$plan_id" "$objective" "$status" "$plan_file"
}

# ── add_plan_task ──
# Adds a task to an existing plan.
# Args: PLAN_ID TASK_ID AGENT SUBJECT REPO OBJECTIVE PRIORITY DEPENDS_ON
# DEPENDS_ON: comma-separated list of task IDs this task depends on (or "none")
add_plan_task() {
  local plan_id="$1"
  local task_id="$2"
  local agent="$3"
  local subject="$4"
  local repo="$5"
  local objective="$6"
  local priority="${7:-P1}"
  local depends_on="${8:-}"

  local plan_file="${PLANS_DIR}/${plan_id}.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan not found: $plan_file" >&2
    return 1
  fi

  python3 -c '
import json, sys

plan_file = sys.argv[1]
task = {
    "task_id": sys.argv[2],
    "agent": sys.argv[3],
    "subject": sys.argv[4],
    "repo": sys.argv[5],
    "objective": sys.argv[6],
    "priority": sys.argv[7],
    "depends_on": [d.strip() for d in sys.argv[8].split(",") if d.strip() and d.strip() != "none"],
    "status": "pending",
    "dispatched": False,
    "result": None
}

with open(plan_file) as f:
    plan = json.load(f)

plan["tasks"].append(task)

with open(plan_file, "w") as f:
    json.dump(plan, f, indent=2)

tid = task["task_id"]
print(f"Added {tid} to plan")
' "$plan_file" "$task_id" "$agent" "$subject" "$repo" "$objective" "$priority" "$depends_on"
}

# ── approve_plan ──
# Marks a plan as approved and ready for dispatch.
approve_plan() {
  local plan_id="$1"
  local plan_file="${PLANS_DIR}/${plan_id}.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan not found: $plan_file" >&2
    return 1
  fi

  python3 -c '
import json, sys
from datetime import datetime, timezone

plan_file = sys.argv[1]
with open(plan_file) as f:
    plan = json.load(f)

plan["status"] = "active"
plan["approved"] = datetime.now(timezone.utc).isoformat()
plan["updated"] = datetime.now(timezone.utc).isoformat()

with open(plan_file, "w") as f:
    json.dump(plan, f, indent=2)

print("Plan approved and active")
' "$plan_file"
}

# ── get_ready_tasks ──
# Returns task IDs that are pending and have all dependencies met.
# Output: one task_id per line
get_ready_tasks() {
  local plan_id="$1"
  local plan_file="${PLANS_DIR}/${plan_id}.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan not found: $plan_file" >&2
    return 1
  fi

  python3 -c '
import json, sys

plan_file = sys.argv[1]
with open(plan_file) as f:
    plan = json.load(f)

if plan["status"] != "active":
    sys.exit(0)

done_ids = {t["task_id"] for t in plan["tasks"] if t["status"] == "done"}

for task in plan["tasks"]:
    if task["status"] != "pending":
        continue
    if task["dispatched"]:
        continue
    deps = task.get("depends_on", [])
    if all(d in done_ids for d in deps):
        print(task["task_id"])
' "$plan_file"
}

# ── dispatch_wave ──
# Dispatches all ready tasks for a plan using dispatch.sh.
# Returns number of tasks dispatched.
dispatch_wave() {
  local plan_id="$1"
  local plan_file="${PLANS_DIR}/${plan_id}.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan not found: $plan_file" >&2
    return 1
  fi

  # Source dispatch.sh for dispatch_task function
  source "$DISPATCH_SCRIPT"

  local dispatched=0
  local ready_tasks
  ready_tasks=$(get_ready_tasks "$plan_id")

  if [[ -z "$ready_tasks" ]]; then
    echo "0"
    return 0
  fi

  while IFS= read -r task_id; do
    [[ -z "$task_id" ]] && continue

    # Get task details from plan
    local task_json
    task_json=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    plan = json.load(f)
for t in plan["tasks"]:
    if t["task_id"] == sys.argv[2]:
        print(json.dumps(t))
        break
' "$plan_file" "$task_id")

    if [[ -z "$task_json" ]]; then
      echo "WARNING: task $task_id not found in plan" >&2
      continue
    fi

    local agent subject repo objective priority
    agent=$(echo "$task_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['agent'])")
    subject=$(echo "$task_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['subject'])")
    repo=$(echo "$task_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['repo'])")
    objective=$(echo "$task_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['objective'])")
    priority=$(echo "$task_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['priority'])")

    # Dispatch based on agent type
    case "$agent" in
      mini|antman|mack|harley)
        dispatch_task "$agent" "$task_id" "$subject" "$repo" \
          "$objective" "$priority" \
          "Files related to: $subject" "Unrelated code" \
          "Task objective met and verified" \
          "Part of plan: $plan_id" 2>/dev/null && {
          mark_dispatched "$plan_id" "$task_id"
          dispatched=$((dispatched + 1))
          echo "Dispatched $task_id to $agent" >&2
        } || echo "ERROR: Failed to dispatch $task_id" >&2
        ;;
      kilabz|oracle)
        dispatch_review "$agent" "$task_id" "$subject" "$repo" \
          "main" "$objective" \
          "Files related to: $subject" "Unrelated code" \
          "Part of plan: $plan_id" 2>/dev/null && {
          mark_dispatched "$plan_id" "$task_id"
          dispatched=$((dispatched + 1))
          echo "Dispatched $task_id to $agent" >&2
        } || echo "ERROR: Failed to dispatch $task_id" >&2
        ;;
      recon)
        dispatch_research "$agent" "$task_id" "$subject" "$repo" \
          "claude-sonnet" "$objective" "$priority" \
          "Related to: $subject" "Unrelated topics" \
          "Part of plan: $plan_id" 2>/dev/null && {
          mark_dispatched "$plan_id" "$task_id"
          dispatched=$((dispatched + 1))
          echo "Dispatched $task_id to $agent" >&2
        } || echo "ERROR: Failed to dispatch $task_id" >&2
        ;;
      smoke)
        dispatch_qa "$agent" "$task_id" "$subject" "$repo" \
          "$objective" "$priority" \
          "Files related to: $subject" "Unrelated code" \
          "Task objective met" \
          "Part of plan: $plan_id" 2>/dev/null && {
          mark_dispatched "$plan_id" "$task_id"
          dispatched=$((dispatched + 1))
          echo "Dispatched $task_id to $agent" >&2
        } || echo "ERROR: Failed to dispatch $task_id" >&2
        ;;
      *)
        echo "ERROR: Unknown agent type: $agent" >&2
        ;;
    esac
  done <<< "$ready_tasks"

  echo "$dispatched"
}

# ── mark_dispatched ──
# Marks a plan task as dispatched (in-flight).
mark_dispatched() {
  local plan_id="$1"
  local task_id="$2"
  local plan_file="${PLANS_DIR}/${plan_id}.json"

  python3 -c '
import json, sys
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    plan = json.load(f)

for t in plan["tasks"]:
    if t["task_id"] == sys.argv[2]:
        t["dispatched"] = True
        t["status"] = "in_progress"
        t["dispatched_at"] = datetime.now(timezone.utc).isoformat()
        break

plan["updated"] = datetime.now(timezone.utc).isoformat()

with open(sys.argv[1], "w") as f:
    json.dump(plan, f, indent=2)
' "$plan_file" "$task_id"
}

# ── mark_plan_task_done ──
# Marks a task as done in the plan. Checks if plan is complete.
# Args: PLAN_ID TASK_ID RESULT(PASS|FAIL)
mark_plan_task_done() {
  local plan_id="$1"
  local task_id="$2"
  local result="${3:-PASS}"
  local plan_file="${PLANS_DIR}/${plan_id}.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan not found: $plan_file" >&2
    return 1
  fi

  python3 -c '
import json, sys
from datetime import datetime, timezone

plan_file = sys.argv[1]
task_id = sys.argv[2]
result = sys.argv[3]

with open(plan_file) as f:
    plan = json.load(f)

found = False
for t in plan["tasks"]:
    if t["task_id"] == task_id:
        t["status"] = "done" if result == "PASS" else "failed"
        t["result"] = result
        t["completed_at"] = datetime.now(timezone.utc).isoformat()
        found = True
        break

if not found:
    print(f"WARNING: task {task_id} not found in plan", file=sys.stderr)
    sys.exit(1)

# Check if all tasks are done
all_done = all(t["status"] in ("done", "failed") for t in plan["tasks"])
all_pass = all(t["status"] == "done" for t in plan["tasks"])

if all_done:
    plan["status"] = "complete" if all_pass else "complete_with_failures"
    plan["completed"] = datetime.now(timezone.utc).isoformat()

plan["updated"] = datetime.now(timezone.utc).isoformat()

with open(plan_file, "w") as f:
    json.dump(plan, f, indent=2)

if all_done:
    if all_pass:
        print("PLAN_COMPLETE")
    else:
        print("PLAN_COMPLETE_WITH_FAILURES")
else:
    print("TASK_DONE")
' "$plan_file" "$task_id" "$result"
}

# ── check_plan_progress ──
# Scans completions directory for tasks belonging to a plan.
# Marks them done in the plan and returns a status summary.
# Output: JSON with plan status
check_plan_progress() {
  local plan_id="$1"
  local plan_file="${PLANS_DIR}/${plan_id}.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan not found: $plan_file" >&2
    return 1
  fi

  python3 -c '
import json, sys, os, re
from datetime import datetime, timezone

plan_file = sys.argv[1]
completions_dir = sys.argv[2]
max_retries = 3

with open(plan_file) as f:
    plan = json.load(f)

if plan["status"] not in ("active",):
    print(json.dumps({"status": plan["status"], "changed": False}))
    sys.exit(0)

# Scan completions for plan task IDs
plan_task_ids = {t["task_id"] for t in plan["tasks"]}
changed = False

for fname in sorted(os.listdir(completions_dir)):
    if not fname.endswith(".md"):
        continue
    fpath = os.path.join(completions_dir, fname)
    try:
        content = open(fpath).read()
    except Exception:
        continue

    # Parse frontmatter
    m = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if not m:
        continue

    lines = m.group(1).split("\n")
    fm = {}
    for line in lines:
        if ":" in line:
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()

    task_id = fm.get("task_id", "")
    result = fm.get("result", "PASS")

    if task_id not in plan_task_ids:
        continue

    # Find the task in plan
    for t in plan["tasks"]:
        if t["task_id"] == task_id and t["status"] == "in_progress":
            if result == "PASS":
                t["status"] = "done"
                t["result"] = result
                t["completed_at"] = datetime.now(timezone.utc).isoformat()
                changed = True
            else:
                # Check retry count
                retries = plan.get("retry_counts", {})
                count = retries.get(task_id, 0) + 1
                retries[task_id] = count
                plan["retry_counts"] = retries

                if count >= max_retries:
                    t["status"] = "failed"
                    t["result"] = f"FAIL (retries exhausted: {count})"
                    changed = True
                else:
                    # Reset for retry
                    t["status"] = "pending"
                    t["dispatched"] = False
                    t["result"] = f"FAIL (retry {count}/{max_retries})"
                    changed = True
            break

# Check if plan is complete
all_done = all(t["status"] in ("done", "failed") for t in plan["tasks"])
if all_done and changed:
    all_pass = all(t["status"] == "done" for t in plan["tasks"])
    plan["status"] = "complete" if all_pass else "complete_with_failures"
    plan["completed"] = datetime.now(timezone.utc).isoformat()

if changed:
    plan["updated"] = datetime.now(timezone.utc).isoformat()
    with open(plan_file, "w") as f:
        json.dump(plan, f, indent=2)

# Summary
summary = {
    "plan_id": plan["plan_id"],
    "status": plan["status"],
    "changed": changed,
    "total": len(plan["tasks"]),
    "done": sum(1 for t in plan["tasks"] if t["status"] == "done"),
    "in_progress": sum(1 for t in plan["tasks"] if t["status"] == "in_progress"),
    "pending": sum(1 for t in plan["tasks"] if t["status"] == "pending"),
    "failed": sum(1 for t in plan["tasks"] if t["status"] == "failed"),
    "ready_to_dispatch": []
}

# Find newly ready tasks
done_ids = {t["task_id"] for t in plan["tasks"] if t["status"] == "done"}
for t in plan["tasks"]:
    if t["status"] == "pending" and not t.get("dispatched"):
        deps = t.get("depends_on", [])
        if all(d in done_ids for d in deps):
            summary["ready_to_dispatch"].append(t["task_id"])

print(json.dumps(summary))
' "$plan_file" "$COMPLETIONS_DIR"
}

# ── get_plan_summary ──
# Returns a human-readable summary of a plan.
get_plan_summary() {
  local plan_id="$1"
  local plan_file="${PLANS_DIR}/${plan_id}.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan not found: $plan_file" >&2
    return 1
  fi

  python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    plan = json.load(f)

pid = plan["plan_id"]
obj = plan["objective"]
st = plan["status"].upper()
print(f"**Plan: {pid}** — {obj}")
print(f"Status: {st}")
print()

# Group by wave (topological order)
done_ids = set()
waves = []
remaining = list(plan["tasks"])

while remaining:
    wave = []
    for t in remaining:
        deps = t.get("depends_on", [])
        if all(d in done_ids for d in deps):
            wave.append(t)
    if not wave:
        # Circular dependency or all remaining have unmet deps
        wave = remaining[:]
    for t in wave:
        remaining.remove(t)
        done_ids.add(t["task_id"])
    waves.append(wave)

for i, wave in enumerate(waves):
    print(f"**Wave {i+1}:**")
    for t in wave:
        status_icon = {"pending": "⏳", "in_progress": "🔄", "done": "✅", "failed": "❌"}.get(t["status"], "❓")
        deps = ", ".join(t.get("depends_on", [])) or "none"
        tid = t["task_id"]
        ag = t["agent"]
        subj = t["subject"]
        print(f"  {status_icon} `{tid}` → [{ag}] {subj} (deps: {deps})")
    print()

total = len(plan["tasks"])
done = sum(1 for t in plan["tasks"] if t["status"] == "done")
print(f"Progress: {done}/{total} tasks complete")
' "$plan_file"
}

# ── list_active_plans ──
# Lists all active plans.
list_active_plans() {
  python3 -c '
import json, os, sys

plans_dir = sys.argv[1]
for fname in sorted(os.listdir(plans_dir)):
    if not fname.endswith(".json"):
        continue
    try:
        with open(os.path.join(plans_dir, fname)) as f:
            plan = json.load(f)
        if plan.get("status") in ("active", "pending_approval"):
            total = len(plan.get("tasks", []))
            done = sum(1 for t in plan.get("tasks", []) if t.get("status") == "done")
            pid = plan["plan_id"]
            pst = plan["status"]
            pobj = plan["objective"]
            print(f"{pid} | {pst} | {done}/{total} | {pobj}")
    except Exception:
        continue
' "$PLANS_DIR"
}

export -f create_plan add_plan_task approve_plan get_ready_tasks dispatch_wave
export -f mark_dispatched mark_plan_task_done check_plan_progress
export -f get_plan_summary list_active_plans
