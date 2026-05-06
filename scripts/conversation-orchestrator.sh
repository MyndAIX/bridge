#!/usr/bin/env bash
#
# conversation-orchestrator.sh — Auto-advance multi-round conversation threads.
#
# Called by the Lobster inbox watcher (or drain-completions) when a result lands.
# Detects if the result belongs to an active thread, and if so:
#   1. Records the round result + output
#   2. Dispatches the next round with all prior context embedded
#   3. Posts progress to #command-center
#   4. When all rounds complete, marks thread done and posts final summary
#
# Usage:
#   bash conversation-orchestrator.sh <result_file>
#   bash conversation-orchestrator.sh --scan   # scan inbox for thread results
#

set -uo pipefail

BRIDGE_DIR="${HOME}/.myndaix/bridge"
THREAD_DIR="${BRIDGE_DIR}/state/threads"
INBOX_DIR="${BRIDGE_DIR}/inbox/lobster"

mkdir -p "$THREAD_DIR"

# Source dispatch functions
source "$BRIDGE_DIR/dispatch.sh" 2>/dev/null || true

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [conv-orch] $*" >&2
}

# Extract task_id from result file frontmatter
get_task_id() {
  local file="$1"
  ruby -Eutf-8 -ryaml -rjson -rdate -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
    exit 0 unless m
    data = YAML.safe_load(m[1], permitted_classes: [Date, Time], aliases: false)
    puts data["task_id"].to_s if data.is_a?(Hash)
  ' "$file" 2>/dev/null || echo ""
}

# Extract body (everything after frontmatter) from a file
get_body() {
  local file="$1"
  ruby -Eutf-8 -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n.*?\n---\s*\n(.*)\z/m)
    puts m ? m[1].strip : ""
  ' "$file" 2>/dev/null || echo ""
}

# Find thread state for a task_id (e.g., CONV-VOICE-001-r2 → thread-CONV-VOICE-001)
find_thread() {
  local task_id="$1"
  # Strip round suffix: TASK-r1 → TASK, TASK-r2 → TASK
  local prefix="${task_id%-r[0-9]*}"
  local thread_id="thread-${prefix}"
  local thread_file="${THREAD_DIR}/${thread_id}.json"

  if [[ -f "$thread_file" ]]; then
    echo "$thread_file"
  else
    echo ""
  fi
}

# Extract round number from task_id (e.g., TASK-r2 → 2)
get_round_from_task_id() {
  local task_id="$1"
  if [[ "$task_id" =~ -r([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Advance a thread to the next round
advance_thread() {
  local thread_file="$1"
  local result_file="$2"
  local result_body="$3"
  local completed_round="$4"

  # Read thread state
  local thread_json
  thread_json=$(cat "$thread_file")

  # Compute next round from the COMPLETED round number (not state's current_round)
  local next_round max_rounds thread_id to task_id_prefix subject repo objective dispatch_type
  next_round=$(( completed_round + 1 ))
  max_rounds=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['max_rounds'])" "$thread_json")
  thread_id=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['thread_id'])" "$thread_json")
  to=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['to'])" "$thread_json")
  task_id_prefix=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['task_id_prefix'])" "$thread_json")
  subject=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['subject'])" "$thread_json")
  repo=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['repo'])" "$thread_json")
  objective=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['objective'])" "$thread_json")
  dispatch_type=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('dispatch_type','task'))" "$thread_json")

  # Record this round's completion in thread state
  python3 - "$thread_file" "$completed_round" "$result_body" <<'PY'
import json, sys
from datetime import datetime, timezone
path, rnd, body = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path) as f:
    state = json.load(f)
# Update the round entry
for r in state["rounds"]:
    if r["round"] == rnd:
        r["status"] = "completed"
        r["completed"] = datetime.now(timezone.utc).isoformat()
        r["output_preview"] = body[:500]
        break
state["current_round"] = rnd
with open(path, "w") as f:
    json.dump(state, f, indent=2)
PY

  # Check if we're done
  if (( next_round > max_rounds )); then
    # Thread complete — mark done
    python3 -c '
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
with open(path) as f:
    state = json.load(f)
state["status"] = "completed"
state["completed"] = datetime.now(timezone.utc).isoformat()
with open(path, "w") as f:
    json.dump(state, f, indent=2)
' "$thread_file"
    log "Thread $thread_id COMPLETE ($max_rounds rounds done)"
    echo "COMPLETE"
    return 0
  fi

  # Build prior context from all completed rounds
  local prior_context
  prior_context=$(python3 - "$thread_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    state = json.load(f)
parts = []
for r in state["rounds"]:
    if r.get("status") == "completed" and r.get("output_preview"):
        parts.append(f"=== Round {r['round']} Output ===\n{r['output_preview']}\n")
print("\n".join(parts))
PY
  )

  # Dispatch next round with prior context embedded
  local next_task_id="${task_id_prefix}-r${next_round}"
  local next_body="## Prior Rounds Context

${prior_context}

## Round ${next_round} Instructions
Continue the discussion. You have the context from rounds 1-${completed_round} above.
Build on the previous findings. Add new insights, challenge assumptions, or refine recommendations.
This is round ${next_round} of ${max_rounds}."

  # Add round to thread state
  python3 - "$thread_file" "$next_round" <<'PY'
import json, sys
from datetime import datetime, timezone
path, rnd = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    state = json.load(f)
state["rounds"].append({"round": rnd, "dispatched": datetime.now(timezone.utc).isoformat(), "status": "dispatched"})
with open(path, "w") as f:
    json.dump(state, f, indent=2)
PY

  # Clear dedupe for next round task_id
  local dedupe_file="${BRIDGE_DIR}/state/dedupe/${next_task_id}.done"
  rm -f "$dedupe_file" 2>/dev/null || true

  # Build and dispatch the next round
  local response_block
  response_block=$(_response_protocol "$to" "$next_task_id")

  local safe_subject safe_objective safe_repo
  safe_subject=$(_sanitize_yaml_scalar "$subject")
  safe_objective=$(_sanitize_yaml_scalar "$objective")
  safe_repo=$(_sanitize_yaml_scalar "$repo")
  local fenced_body
  fenced_body=$(_fence_content "$next_body")

  local content
  if [[ "$dispatch_type" == "review" ]]; then
    content="---
from: lobster
to: ${to}
type: review
subject: \"${safe_subject} (round ${next_round}/${max_rounds})\"
task_id: ${next_task_id}
thread_id: ${thread_id}
round: ${next_round}
max_rounds: ${max_rounds}
repo: ${safe_repo}
branch: main
objective: \"${safe_objective}\"
tier: auto
---

${fenced_body}
${response_block}"
  else
    content="---
from: lobster
to: ${to}
type: task
subject: \"${safe_subject} (round ${next_round}/${max_rounds})\"
task_id: ${next_task_id}
thread_id: ${thread_id}
round: ${next_round}
max_rounds: ${max_rounds}
repo: ${safe_repo}
objective: \"${safe_objective}\"
priority: P1
tier: auto
done_criteria:
  - Complete round ${next_round} of ${max_rounds} discussion
---

${fenced_body}
${response_block}"
  fi

  local filename="lobster-to-${to}-${next_task_id}.md"
  _write_dispatch "$to" "$filename" "$content"

  log "Thread $thread_id advanced to round ${next_round}/${max_rounds}"
  echo "ADVANCED:${next_round}/${max_rounds}"
  return 0
}

# Process a single result file — check if it belongs to a thread
process_result() {
  local result_file="$1"

  local task_id
  task_id=$(get_task_id "$result_file")
  [[ -z "$task_id" ]] && return 0

  local thread_file
  thread_file=$(find_thread "$task_id")
  [[ -z "$thread_file" ]] && return 0

  local round_num
  round_num=$(get_round_from_task_id "$task_id")
  [[ -z "$round_num" ]] && return 0

  # Check thread is still active
  local thread_status
  thread_status=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('status',''))" "$thread_file" 2>/dev/null)
  if [[ "$thread_status" != "active" ]]; then
    log "Thread for $task_id is $thread_status — skipping"
    return 0
  fi

  local result_body
  result_body=$(get_body "$result_file")

  local outcome
  outcome=$(advance_thread "$thread_file" "$result_file" "$result_body" "$round_num")

  local thread_id
  thread_id=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['thread_id'])" "$thread_file" 2>/dev/null)

  # Post status to Discord #command-center
  if command -v openclaw >/dev/null 2>&1; then
    local msg=""
    if [[ "$outcome" == "COMPLETE" ]]; then
      msg="🏁 **Thread complete:** ${thread_id} — all rounds finished. Final output in inbox."
    elif [[ "$outcome" == ADVANCED:* ]]; then
      local progress="${outcome#ADVANCED:}"
      msg="🔄 **Thread ${thread_id}** — round ${progress} dispatched (auto-advanced)"
    fi
    if [[ -n "$msg" ]]; then
      openclaw message send --channel discord -t "${DISCORD_COMMAND_CHANNEL:-}" \
        -m "$msg" --silent 2>/dev/null &
    fi
  fi

  echo "$outcome"
}

# --- Main ---

if [[ "${1:-}" == "--scan" ]]; then
  # Scan inbox for any thread results
  found=0
  for f in "$INBOX_DIR"/*-result.md; do
    [[ -f "$f" ]] || continue
    result=$(process_result "$f")
    if [[ -n "$result" ]]; then
      found=$((found + 1))
      log "Processed thread result: $(basename "$f") → $result"
    fi
  done
  if (( found == 0 )); then
    echo "NO_THREAD_RESULTS"
  fi
elif [[ -n "${1:-}" && -f "${1:-}" ]]; then
  process_result "$1"
else
  echo "Usage: $0 <result_file> | --scan" >&2
  exit 1
fi
