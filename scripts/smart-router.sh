#!/bin/bash
# smart-router.sh — Complexity-based model selection for MyndAIX agents
# Usage: source this, then call select_model "$TASK_FILE"
#
# Reads task file, classifies complexity, returns appropriate model.
# Agents call this before spawning Claude CLI to pick the right tier.

select_model() {
  local task_file="$1"
  local default_model="${2:-claude-sonnet-4-20250514}"
  
  if [[ ! -f "$task_file" ]]; then
    echo "$default_model"
    return
  fi
  
  local word_count task_type has_code
  word_count=$(wc -w < "$task_file" | tr -d ' ')
  task_type=$(grep -m1 "^type:" "$task_file" | cut -d: -f2 | tr -d ' "' || echo "unknown")
  has_code=$(grep -c '```' "$task_file" 2>/dev/null) || has_code=0
  
  # Tier 1: Simple tasks — use Haiku (cheapest, fastest)
  # Short messages, status checks, acknowledgments
  if [[ $word_count -lt 100 && "$task_type" =~ ^(message|response|alert|info)$ ]]; then
    echo "claude-haiku-4-5-20251001"
    return
  fi
  
  # Tier 3: Complex tasks — use Opus (most capable)
  # Long tasks, architecture, multi-file reviews, code with many blocks
  if [[ $word_count -gt 500 || "$task_type" =~ ^(architecture|design|strategy)$ || $has_code -gt 4 ]]; then
    echo "claude-opus-4-6"
    return
  fi
  
  # Tier 2: Everything else — use Sonnet (balanced)
  echo "$default_model"
}

# Read outcomes CSV and suggest best agent for a task type
suggest_agent() {
  local task_type="$1"
  local outcomes_file="$HOME/.myndaix/memory/outcomes.csv"
  
  if [[ ! -f "$outcomes_file" ]]; then
    echo ""
    return
  fi
  
  # Find agent with highest success rate for this task type
  python3 -c "
import csv, sys
from collections import defaultdict

task_type = sys.argv[1]
scores = defaultdict(lambda: {'pass': 0, 'fail': 0, 'total': 0})

with open(sys.argv[2]) as f:
    reader = csv.DictReader(f)
    for row in reader:
        agent = row.get('agent', '')
        result = row.get('result', '').upper()
        task = row.get('task', '')
        
        if not agent:
            continue
        
        scores[agent]['total'] += 1
        if result in ('PASS', 'SUCCESS', 'COMPLETED', 'DONE'):
            scores[agent]['pass'] += 1
        else:
            scores[agent]['fail'] += 1

# Rank by success rate (min 3 tasks to qualify)
ranked = []
for agent, s in scores.items():
    if s['total'] >= 3:
        rate = s['pass'] / s['total']
        ranked.append((agent, rate, s['total']))

ranked.sort(key=lambda x: (-x[1], -x[2]))
if ranked:
    print(ranked[0][0])
" "$task_type" "$outcomes_file" 2>/dev/null
}
