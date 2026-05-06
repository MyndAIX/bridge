#!/usr/bin/env bash
# cost-report.sh — Query MyndAIX cost/token usage
# Usage: cost-report.sh [today|week|all|agent <name>]

COST_LOG="${COST_LOG:-$HOME/.myndaix/bridge/state/cost-log.jsonl}"

if [[ ! -f "$COST_LOG" ]]; then
  echo "No cost data yet. Cost log: $COST_LOG"
  exit 0
fi

MODE="${1:-today}"
AGENT_FILTER="${2:-}"

python3 - "$COST_LOG" "$MODE" "$AGENT_FILTER" << 'PY'
import json, sys
from datetime import datetime, timedelta, timezone

log_file = sys.argv[1]
mode = sys.argv[2]
agent_filter = sys.argv[3] if len(sys.argv) > 3 else ""

now = datetime.now(timezone.utc)
today = now.strftime('%Y-%m-%d')
week_ago = (now - timedelta(days=7)).strftime('%Y-%m-%dT')

entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

# Filter by mode
if mode == "today":
    entries = [e for e in entries if e.get('ts', '').startswith(today)]
    title = f"Today ({today})"
elif mode == "week":
    entries = [e for e in entries if e.get('ts', '') >= week_ago]
    title = "Last 7 days"
elif mode == "agent" and agent_filter:
    entries = [e for e in entries if e.get('agent') == agent_filter]
    title = f"Agent: {agent_filter}"
else:
    title = "All time"

if not entries:
    print(f"\n{title}: No data.\n")
    sys.exit(0)

# Aggregate
total_cost = sum(e.get('cost_usd', 0) for e in entries)
total_input = sum(e.get('input_tokens', 0) for e in entries)
total_output = sum(e.get('output_tokens', 0) for e in entries)
total_cache_read = sum(e.get('cache_read', 0) for e in entries)
total_cache_write = sum(e.get('cache_write', 0) for e in entries)
total_tasks = len(entries)

# Per-agent breakdown
by_agent = {}
for e in entries:
    a = e.get('agent', 'unknown')
    if a not in by_agent:
        by_agent[a] = {'tasks': 0, 'cost': 0, 'input': 0, 'output': 0}
    by_agent[a]['tasks'] += 1
    by_agent[a]['cost'] += e.get('cost_usd', 0)
    by_agent[a]['input'] += e.get('input_tokens', 0)
    by_agent[a]['output'] += e.get('output_tokens', 0)

# Per-engine breakdown
by_engine = {}
for e in entries:
    eng = e.get('engine', 'unknown')
    if eng not in by_engine:
        by_engine[eng] = {'tasks': 0, 'cost': 0}
    by_engine[eng]['tasks'] += 1
    by_engine[eng]['cost'] += e.get('cost_usd', 0)

print(f"\n{'='*50}")
print(f"MyndAIX Cost Report — {title}")
print(f"{'='*50}")
print(f"Total tasks:    {total_tasks}")
print(f"Total cost:     ${total_cost:.4f}")
print(f"Input tokens:   {total_input:,}")
print(f"Output tokens:  {total_output:,}")
print(f"Cache read:     {total_cache_read:,}")
print(f"Cache write:    {total_cache_write:,}")
print(f"Avg cost/task:  ${total_cost/total_tasks:.4f}" if total_tasks > 0 else "")

print(f"\n--- By Agent ---")
for a, d in sorted(by_agent.items(), key=lambda x: -x[1]['cost']):
    print(f"  {a:12s}  {d['tasks']:3d} tasks  ${d['cost']:8.4f}  ({d['input']:,} in / {d['output']:,} out)")

print(f"\n--- By Engine ---")
for eng, d in sorted(by_engine.items(), key=lambda x: -x[1]['cost']):
    print(f"  {eng:30s}  {d['tasks']:3d} tasks  ${d['cost']:8.4f}")

print()
PY
