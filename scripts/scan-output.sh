#!/bin/bash
set -euo pipefail
#
# scan-output.sh — MyndAIX Output Fingerprint Scanner v1.0
#
# PASSIVE MODE: Logs matches, does NOT block output.
# After 2 weeks of calibration, evaluate false positive rate before enforcing.
#
# What it does:
#   1. Reads agent output file
#   2. Extracts significant phrases (>40 chars) from all protected files
#   3. Checks if any phrases appear verbatim in the output
#   4. Logs matches to audit log with severity
#   5. Tags result file if protected content was involved
#
# Usage:
#   scan-output.sh <output_file> [--agent <agent_id>] [--task-id <task_id>]
#
# Exit codes:
#   0 = clean or matches found (passive mode — always 0)
#   Non-zero only on script error
#

PROTECTED_DIR="$HOME/.myndaix/protected"
MANIFEST="$PROTECTED_DIR/.manifest.yaml"
SCAN_LOG="$HOME/.myndaix/logs/output-scan.log"

OUTPUT_FILE="${1:-}"
AGENT_ID="unknown"
TASK_ID="unknown"

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT_ID="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$OUTPUT_FILE" ]] || [[ ! -f "$OUTPUT_FILE" ]]; then
  exit 0
fi

scan_log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "$ts agent=$AGENT_ID task=$TASK_ID $*" >> "$SCAN_LOG" 2>/dev/null || true
}

# Run the scan
python3 - "$OUTPUT_FILE" "$PROTECTED_DIR" "$MANIFEST" "$AGENT_ID" "$TASK_ID" "$SCAN_LOG" << 'PYSCAN'
import sys, os, re

output_file = sys.argv[1]
protected_dir = sys.argv[2]
manifest_path = sys.argv[3]
agent_id = sys.argv[4]
task_id = sys.argv[5]
scan_log = sys.argv[6]

# Read output
try:
    with open(output_file) as f:
        output = f.read()
except Exception:
    sys.exit(0)

if not output.strip():
    sys.exit(0)

# Parse manifest to get protected file list
protected_files = []
try:
    with open(manifest_path) as f:
        content = f.read()
    entries = re.findall(
        r'-\s*name:\s*(.+?)\n\s*(?:description:[^\n]*\n\s*)?agents:\s*\[([^\]]*)\]',
        content
    )
    for name, _ in entries:
        protected_files.append(name.strip())
except Exception:
    sys.exit(0)

# Extract fingerprints from each protected file and check against output
matches = []
for filename in protected_files:
    filepath = os.path.join(protected_dir, filename)
    if not os.path.isfile(filepath):
        continue

    try:
        with open(filepath) as f:
            protected_content = f.read()
    except Exception:
        continue

    # Extract significant phrases: sentences > 40 chars
    phrases = [p.strip() for p in re.split(r'[.!\n]', protected_content) if len(p.strip()) > 40]

    for phrase in phrases[:30]:  # cap at 30 phrases per file to limit scan time
        if phrase in output:
            matches.append({
                "file": filename,
                "phrase": phrase[:80],
                "severity": "HIGH"
            })

# Log results
try:
    from datetime import datetime, timezone
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    with open(scan_log, "a") as log:
        if matches:
            for m in matches:
                log.write(f'{ts} agent={agent_id} task={task_id} action=LEAK_DETECTED '
                         f'file={m["file"]} severity={m["severity"]} '
                         f'phrase="{m["phrase"]}"\n')
            # Print summary to stderr for runner visibility
            print(f"[scan-output] WARNING: {len(matches)} potential leak(s) detected. See {scan_log}", file=sys.stderr)
        else:
            log.write(f'{ts} agent={agent_id} task={task_id} action=SCAN_CLEAN matches=0\n')
except Exception:
    pass

# PASSIVE MODE: always exit 0 — log only, don't block
sys.exit(0)
PYSCAN
