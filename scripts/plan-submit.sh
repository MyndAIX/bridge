#!/usr/bin/env bash
#
# plan-submit.sh — Entry point for /plan command.
#
# Creates a plan from a JSON task array. Lobster does the LLM decomposition
# in-head and feeds the result here.
#
# Usage:
#   bash plan-submit.sh --id MX-PLAN-001 --objective "Ship FieldVision PWA" --tasks '[...]'
#   bash plan-submit.sh --id MX-PLAN-001 --objective "Ship FieldVision PWA" --tasks-file /tmp/tasks.json
#   bash plan-submit.sh --approve MX-PLAN-001
#   bash plan-submit.sh --status MX-PLAN-001
#   bash plan-submit.sh --list
#
# Task JSON format (array):
# [
#   {
#     "task_id": "MX-070",
#     "agent": "recon",
#     "subject": "Research PWA frameworks",
#     "repo": "FieldVision",
#     "objective": "Find best PWA framework for iOS-first app",
#     "priority": "P1",
#     "depends_on": []
#   },
#   ...
# ]
#
# Max 8 tasks per plan. Agent must be: mini|antman|mack|harley|kilabz|oracle|recon|smoke
#

set -uo pipefail

BRIDGE_DIR="${HOME}/.myndaix/bridge"
SCRIPTS_DIR="${BRIDGE_DIR}/scripts"
PLAN_ENGINE="${SCRIPTS_DIR}/plan-engine.sh"

# Source plan engine
if [[ ! -f "$PLAN_ENGINE" ]]; then
  echo "ERROR: plan-engine.sh not found" >&2
  exit 1
fi
source "$PLAN_ENGINE"

# ── Parse args ──
ACTION="create"
PLAN_ID=""
OBJECTIVE=""
TASKS_JSON=""
TASKS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)         PLAN_ID="$2"; shift 2 ;;
    --objective)  OBJECTIVE="$2"; shift 2 ;;
    --tasks)      TASKS_JSON="$2"; shift 2 ;;
    --tasks-file) TASKS_FILE="$2"; shift 2 ;;
    --approve)    ACTION="approve"; PLAN_ID="$2"; shift 2 ;;
    --status)     ACTION="status"; PLAN_ID="$2"; shift 2 ;;
    --list)       ACTION="list"; shift ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Actions ──

case "$ACTION" in
  list)
    echo "**Active Plans:**"
    result=$(list_active_plans 2>/dev/null)
    if [[ -z "$result" ]]; then
      echo "No active plans."
    else
      echo "$result"
    fi
    exit 0
    ;;

  status)
    if [[ -z "$PLAN_ID" ]]; then
      echo "ERROR: --status requires plan ID" >&2
      exit 1
    fi
    get_plan_summary "$PLAN_ID"
    exit $?
    ;;

  approve)
    if [[ -z "$PLAN_ID" ]]; then
      echo "ERROR: --approve requires plan ID" >&2
      exit 1
    fi
    approve_plan "$PLAN_ID"
    # Dispatch first wave immediately
    echo "Dispatching first wave..."
    dispatched=$(dispatch_wave "$PLAN_ID" 2>&1)
    echo "Dispatched: $dispatched tasks"
    echo ""
    get_plan_summary "$PLAN_ID"
    exit 0
    ;;

  create)
    # Validate required fields
    if [[ -z "$PLAN_ID" ]]; then
      echo "ERROR: --id required" >&2
      exit 1
    fi
    if [[ -z "$OBJECTIVE" ]]; then
      echo "ERROR: --objective required" >&2
      exit 1
    fi

    # Get tasks JSON from arg or file
    if [[ -n "$TASKS_FILE" ]]; then
      if [[ ! -f "$TASKS_FILE" ]]; then
        echo "ERROR: Tasks file not found: $TASKS_FILE" >&2
        exit 1
      fi
      TASKS_JSON=$(cat "$TASKS_FILE")
    fi

    if [[ -z "$TASKS_JSON" ]]; then
      echo "ERROR: --tasks or --tasks-file required" >&2
      exit 1
    fi

    # Validate and create plan via Python (single atomic operation)
    python3 -c '
import json, sys, os
from datetime import datetime, timezone

plan_id = sys.argv[1]
objective = sys.argv[2]
tasks_json = sys.argv[3]
plans_dir = sys.argv[4]

# Parse tasks
try:
    tasks = json.loads(tasks_json)
except json.JSONDecodeError as e:
    print(f"ERROR: Invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(tasks, list):
    print("ERROR: Tasks must be a JSON array", file=sys.stderr)
    sys.exit(1)

if len(tasks) > 8:
    print(f"ERROR: Max 8 tasks per plan, got {len(tasks)}", file=sys.stderr)
    sys.exit(1)

if len(tasks) == 0:
    print("ERROR: At least 1 task required", file=sys.stderr)
    sys.exit(1)

# Validate agents
valid_agents = {"mini", "antman", "mack", "harley", "kilabz", "oracle", "recon", "smoke"}
for t in tasks:
    required = ["task_id", "agent", "subject", "repo", "objective"]
    for field in required:
        if field not in t:
            print(f"ERROR: Task missing field \"{field}\": {json.dumps(t)}", file=sys.stderr)
            sys.exit(1)
    if t["agent"] not in valid_agents:
        agent_name = t["agent"]
        print(f"ERROR: Invalid agent \"{agent_name}\" — must be one of: {sorted(valid_agents)}", file=sys.stderr)
        sys.exit(1)

# Validate DAG — check for circular deps
task_ids = {t["task_id"] for t in tasks}
for t in tasks:
    deps = t.get("depends_on", [])
    for d in deps:
        if d not in task_ids:
            tid = t["task_id"]
            print(f"ERROR: Task \"{tid}\" depends on \"{d}\" which is not in this plan", file=sys.stderr)
            sys.exit(1)

# Simple cycle detection (topological sort)
in_degree = {t["task_id"]: 0 for t in tasks}
adjacency = {t["task_id"]: [] for t in tasks}
for t in tasks:
    for d in t.get("depends_on", []):
        adjacency[d].append(t["task_id"])
        in_degree[t["task_id"]] += 1

queue = [tid for tid, deg in in_degree.items() if deg == 0]
sorted_count = 0
while queue:
    node = queue.pop(0)
    sorted_count += 1
    for neighbor in adjacency[node]:
        in_degree[neighbor] -= 1
        if in_degree[neighbor] == 0:
            queue.append(neighbor)

if sorted_count != len(tasks):
    print("ERROR: Circular dependency detected in task graph", file=sys.stderr)
    sys.exit(1)

# Build plan
now = datetime.now(timezone.utc).isoformat()
plan = {
    "plan_id": plan_id,
    "objective": objective,
    "status": "pending_approval",
    "created": now,
    "updated": now,
    "tasks": [],
    "max_retries": 3,
    "retry_counts": {}
}

for t in tasks:
    plan["tasks"].append({
        "task_id": t["task_id"],
        "agent": t["agent"],
        "subject": t["subject"],
        "repo": t["repo"],
        "objective": t["objective"],
        "priority": t.get("priority", "P1"),
        "depends_on": t.get("depends_on", []),
        "status": "pending",
        "dispatched": False,
        "result": None
    })

# Write plan
plan_file = os.path.join(plans_dir, f"{plan_id}.json")
with open(plan_file, "w") as f:
    json.dump(plan, f, indent=2)

# Print summary
print(f"Plan created: {plan_id}")
print(f"Objective: {objective}")
print(f"Tasks: {len(tasks)}")
print(f"Status: pending_approval")
print()

# Show waves
done_ids = set()
waves = []
remaining = list(plan["tasks"])
while remaining:
    wave = [t for t in remaining if all(d in done_ids for d in t.get("depends_on", []))]
    if not wave:
        wave = remaining[:]
    for t in wave:
        remaining.remove(t)
        done_ids.add(t["task_id"])
    waves.append(wave)

for i, wave in enumerate(waves):
    print(f"Wave {i+1}:")
    for t in wave:
        deps = ", ".join(t.get("depends_on", [])) or "none"
        ag = t["agent"]
        tid = t["task_id"]
        subj = t["subject"]
        print(f"  [{ag}] {tid}: {subj} (deps: {deps})")
    print()

print("Awaiting approval. Run with --approve to activate and dispatch wave 1.")
' "$PLAN_ID" "$OBJECTIVE" "$TASKS_JSON" "$PLANS_DIR"
    exit $?
    ;;
esac
