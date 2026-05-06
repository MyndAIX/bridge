#!/bin/bash
# gemini-api.sh — Direct Gemini REST API wrapper (no CLI/TTY dependency)
# Usage: source this, then call gemini_api_generate "prompt" [model] [timeout_secs]
# Requires: GEMINI_API_KEY env var

gemini_api_generate() {
  local prompt="$1"
  local model="${2:-gemini-2.5-pro}"
  local timeout_secs="${3:-300}"
  local api_key="${GEMINI_API_KEY:-}"

  if [[ -z "$api_key" ]]; then
    echo "ERROR: GEMINI_API_KEY not set" >&2
    return 1
  fi

  # Escape prompt for JSON
  local json_prompt
  json_prompt=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$prompt")

  local url="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${api_key}"

  local response
  response=$(curl -s --max-time "$timeout_secs" "$url" \
    -H 'Content-Type: application/json' \
    -d "{\"contents\":[{\"parts\":[{\"text\":${json_prompt}}]}],\"generationConfig\":{\"maxOutputTokens\":8192}}" 2>&1)

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "ERROR: curl failed (rc=$rc)" >&2
    return 1
  fi

  # Extract text from response
  local text
  text=$(python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    if 'error' in r:
        print('API ERROR: ' + r['error'].get('message','unknown'), file=sys.stderr)
        sys.exit(1)
    parts = r.get('candidates',[{}])[0].get('content',{}).get('parts',[])
    print(''.join(p.get('text','') for p in parts))
except Exception as e:
    print(f'Parse error: {e}', file=sys.stderr)
    sys.exit(1)
" <<< "$response")

  local parse_rc=$?
  if [[ $parse_rc -ne 0 ]]; then
    return 1
  fi

  echo "$text"
  return 0
}
