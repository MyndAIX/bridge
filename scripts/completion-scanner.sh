#!/usr/bin/env bash
#
# completion-scanner.sh — Phase 2 auto-loop closer
#
# Scans state/completions/ for builder tasks that don't have a matching
# Oracle review completion. Dispatches Oracle review for unreviewed work.
#
# Usage:
#   bash completion-scanner.sh [--dry-run]
#
# Tracking: state/completion-scanner-state.json holds last-scanned filename
# to avoid re-processing old completions.
#

set -uo pipefail

BRIDGE_DIR="${HOME}/.myndaix/bridge"
COMPLETIONS_DIR="${BRIDGE_DIR}/state/completions"
SCANNER_STATE="${BRIDGE_DIR}/state/completion-scanner-state.json"
SCRIPTS_DIR="${BRIDGE_DIR}/scripts"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

mkdir -p "$COMPLETIONS_DIR"

# ── Single Python pass: scan, match, output ──
SCAN_OUTPUT=$(python3 << 'PYEOF'
import json, os, sys, re

bridge = os.path.expanduser("~/.myndaix/bridge")
completions_dir = os.path.join(bridge, "state/completions")
state_file = os.path.join(bridge, "state/completion-scanner-state.json")

# Load last-scanned marker
last_scanned = ""
if os.path.exists(state_file):
    try:
        last_scanned = json.load(open(state_file)).get("last_scanned", "")
    except Exception:
        pass

builders = {"mini", "antman", "mack", "harley"}

def parse_completions(directory):
    """Parse all .md completion files in a directory."""
    results = []
    if not os.path.isdir(directory):
        return results
    for fname in sorted(os.listdir(directory)):
        if not fname.endswith(".md"):
            continue
        fpath = os.path.join(directory, fname)
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
        fm["_filename"] = fname
        results.append(fm)
    return results

# Parse current (unprocessed) completions — these are candidates for review
current_completions = parse_completions(completions_dir)

# Parse processed completions — needed for oracle match history
processed_dir = os.path.join(completions_dir, "processed")
processed_completions = parse_completions(processed_dir)

# Combine all for oracle coverage check
all_completions = processed_completions + current_completions

# Build set of oracle-reviewed identifiers
# Oracle auto-review filenames: {timestamp}-{agent}-oracle-review-{hash}.md
# Oracle completions reference these in task_id
# Key insight: the timestamp in the oracle review matches the builder completion timestamp
# e.g., builder: 20260330035334-mini.md → oracle review: 20260330035334-mini-oracle-review-*.md
oracle_reviewed_timestamps = set()  # (timestamp_int, agent) tuples oracle reviewed
oracle_reviewed_task_ids = set()  # explicit task_ids oracle reviewed

for c in all_completions:
    if c.get("agent") != "oracle":
        continue
    tid = c.get("task_id", "")
    oracle_reviewed_task_ids.add(tid)
    # Extract the timestamp-agent prefix from oracle review task_id
    # Format: "20260330035334-mini-oracle-review-6a448a0b.md"
    m2 = re.match(r"^(\d{14})-(\w+)-oracle-review-", tid)
    if m2:
        oracle_reviewed_timestamps.add((int(m2.group(1)), m2.group(2)))

def is_reviewed(fname, task_id, agent):
    """Check if a builder completion has a matching oracle review.
    Matches on: exact task_id, task_id substring, or timestamp within ±5s."""
    # Direct task_id match
    if task_id in oracle_reviewed_task_ids:
        return True
    if any(task_id in oid for oid in oracle_reviewed_task_ids):
        return True
    # Timestamp-based match (±5s window for race conditions)
    m3 = re.match(r"^(\d{14})-", fname)
    if m3:
        ts = int(m3.group(1))
        for (ots, oagent) in oracle_reviewed_timestamps:
            if oagent == agent and abs(ts - ots) <= 5:
                return True
    return False

# Only scan current (unprocessed) completions for new reviews needed
new_completions = [c for c in current_completions if not last_scanned or c["_filename"] > last_scanned]
needs_review = []

for c in new_completions:
    agent = c.get("agent", "")
    if agent not in builders:
        continue
    if c.get("result", "") != "PASS":
        continue

    task_id = c.get("task_id", "unknown")
    fname = c["_filename"]

    reviewed = is_reviewed(fname, task_id, agent)

    if not reviewed:
        needs_review.append({
            "agent": agent,
            "task_id": task_id,
            "task_name": c.get("task_name", "unknown"),
            "repo": c.get("repo", ""),
            "branch": c.get("branch", ""),
            "filename": fname
        })

latest = current_completions[-1]["_filename"] if current_completions else last_scanned

print(json.dumps({
    "scanned": len(new_completions),
    "needs_review": needs_review,
    "latest_file": latest
}))
PYEOF
)

if [[ -z "$SCAN_OUTPUT" ]]; then
  echo "ERROR: Scanner failed" >&2
  exit 1
fi

NEEDS_REVIEW=$(echo "$SCAN_OUTPUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['needs_review']))")
LATEST=$(echo "$SCAN_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['latest_file'])")

# Dispatch reviews for unreviewed completions
if [[ "$NEEDS_REVIEW" -gt 0 && "$DRY_RUN" == "false" ]]; then
  echo "$SCAN_OUTPUT" | python3 -c '
import json, sys
for item in json.load(sys.stdin)["needs_review"]:
    print(f"{item[\"agent\"]}|{item[\"task_id\"]}|{item[\"task_name\"]}|{item.get(\"repo\",\"\")}|{item.get(\"branch\",\"\")}")
' | while IFS='|' read -r agent task_id task_name repo branch; do
    bash "$SCRIPTS_DIR/dispatch-oracle-review.sh" "$agent" "$task_name" "$repo" "${branch:-main}" "" ""
    echo "Dispatched Oracle review for $task_id ($agent)"
  done
fi

# Update scanner state
if [[ -n "$LATEST" && "$DRY_RUN" == "false" ]]; then
  printf '{"last_scanned": "%s", "updated": "%s"}\n' "$LATEST" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$SCANNER_STATE"
fi

# Output summary
echo "$SCAN_OUTPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
nr = len(d['needs_review'])
if d['scanned'] == 0 and nr == 0:
    print('NO_NEW_COMPLETIONS')
else:
    items = '; '.join(r['task_id'] + ' (' + r['agent'] + ')' for r in d['needs_review']) if nr > 0 else 'none'
    print('Scanned ' + str(d['scanned']) + ' new, ' + str(nr) + ' need review: ' + items)
"
