#!/bin/bash
# agent-runner.sh — Codex-first, Ollama-fallback agent runner
# Usage: agent-runner.sh <agent-name> <task-file> <repo-path> <timeout> [sandbox-mode]
# sandbox-mode: "full" (default, can write files) or "read-only" (review only)
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

AGENT="$1"
TASK_FILE="$2"
REPO="${3:-${DEFAULT_REPO:-$HOME/.openclaw/workspace}}"
TIMEOUT="${4:-300}"
SANDBOX="${5:-full}"
LOG="$HOME/.myndaix/bridge/watchers/agent-runner.log"

# Per-agent model selection
case "$AGENT" in
  kilabz)
    OLLAMA_MODEL="kilabz-reviewer"
    OLLAMA_FALLBACK="devstral"
    ;;
  *)
    OLLAMA_MODEL="qwen2.5-coder:14b"
    OLLAMA_FALLBACK="qwen2.5-coder:7b"
    ;;
esac

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT] $*" >> "$LOG"; }

# Read task content
TASK_CONTENT=$(cat "$TASK_FILE")

# --- Try 1: Codex CLI ---
log "Trying Codex CLI..."
TEMP_OUT="/tmp/agent-runner-out-$$.md"
TEMP_ERR="/tmp/agent-runner-err-$$.log"
TEMP_PROMPT="/tmp/agent-runner-prompt-$$.md"
echo "$TASK_CONTENT" > "$TEMP_PROMPT"

CODEX_OK=false
if [ "$SANDBOX" = "read-only" ]; then
  SANDBOX_FLAG="--sandbox read-only"
else
  SANDBOX_FLAG="--dangerously-bypass-approvals-and-sandbox"
fi
codex exec -m gpt-5.3-codex -C "$REPO" $SANDBOX_FLAG \
  --skip-git-repo-check --ephemeral - < "$TEMP_PROMPT" > "$TEMP_OUT" 2> "$TEMP_ERR" &
CODEX_PID=$!

# Timeout guard
( sleep "$TIMEOUT" && kill -TERM "$CODEX_PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$CODEX_PID" 2>/dev/null
CODEX_EXIT=$?
kill "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true

if [ "$CODEX_EXIT" -eq 0 ] && [ -s "$TEMP_OUT" ]; then
  CODEX_OK=true
  log "Codex succeeded"
  echo "ENGINE=codex"
  cat "$TEMP_OUT"
  rm -f "$TEMP_OUT" "$TEMP_ERR" "$TEMP_PROMPT"
  exit 0
fi

# Codex failed — always fall back to Ollama regardless of reason
# (rate limit, auth failure, timeout, or any other error)
log "Codex failed (exit=$CODEX_EXIT) — falling back to Ollama"
if [ -f "$TEMP_ERR" ]; then
  ERR_SUMMARY=$(tail -3 "$TEMP_ERR" 2>/dev/null | tr '\n' ' ')
  log "Codex stderr: $ERR_SUMMARY"
fi

# --- Try 2: Ollama fallback (with tool-calling agent loop) ---
log "Falling back to Ollama ($OLLAMA_MODEL)..."
rm -f "$TEMP_OUT"

AGENT_LOOP="$HOME/.myndaix/bridge/ollama-agent-loop.py"

# Check Ollama is running
if ! curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
  log "Ollama not running — attempting start"
  brew services start ollama 2>/dev/null
  sleep 3
fi

# Check if primary model is available via API
AVAILABLE_MODEL="$OLLAMA_MODEL"
MODELS_JSON=$(curl -s http://localhost:11434/api/tags 2>/dev/null)
if ! echo "$MODELS_JSON" | grep -q "$OLLAMA_MODEL"; then
  if echo "$MODELS_JSON" | grep -q "$OLLAMA_FALLBACK"; then
    AVAILABLE_MODEL="$OLLAMA_FALLBACK"
    log "$OLLAMA_MODEL not available, using fallback $OLLAMA_FALLBACK"
  else
    log "No Ollama models available for $AGENT — aborting"
    echo "ENGINE=none"
    echo "No engine available: Codex rate limited, no Ollama models for $AGENT."
    rm -f "$TEMP_OUT" "$TEMP_ERR" "$TEMP_PROMPT"
    exit 1
  fi
fi

# Pre-read files mentioned in the task and inject into prompt
# This gives the model actual code context without needing tool calling
ENRICHED_PROMPT="/tmp/agent-runner-enriched-$$.md"
python3 "$HOME/.myndaix/bridge/ollama-enrich-prompt.py" "$REPO" < "$TEMP_PROMPT" > "$ENRICHED_PROMPT" 2>/dev/null
if [ -s "$ENRICHED_PROMPT" ]; then
  INJECT_PROMPT="$ENRICHED_PROMPT"
  INJECTED_SIZE=$(wc -c < "$ENRICHED_PROMPT")
  log "Enriched prompt with file contents ($INJECTED_SIZE bytes)"
else
  INJECT_PROMPT="$TEMP_PROMPT"
  log "No files to inject, using original prompt"
fi

# Run the tool-calling agent loop (with enriched prompt)
log "Running ollama-agent-loop.py ($AVAILABLE_MODEL, sandbox=$SANDBOX)..."
python3 "$AGENT_LOOP" "$REPO" "$AVAILABLE_MODEL" "$SANDBOX" "$TIMEOUT" "$LOG" \
  < "$INJECT_PROMPT" > "$TEMP_OUT" 2> "$TEMP_ERR"
OLLAMA_EXIT=$?
rm -f "$ENRICHED_PROMPT"

if [ "$OLLAMA_EXIT" -eq 0 ] && [ -s "$TEMP_OUT" ]; then
  log "Ollama agent loop succeeded ($AVAILABLE_MODEL)"
  echo "ENGINE=ollama:$AVAILABLE_MODEL"
  cat "$TEMP_OUT"
  rm -f "$TEMP_OUT" "$TEMP_ERR" "$TEMP_PROMPT"
  exit 0
fi

log "Ollama failed (exit=$OLLAMA_EXIT)"
echo "ENGINE=none"
echo "Both Codex and Ollama failed."
[ -f "$TEMP_ERR" ] && cat "$TEMP_ERR"
rm -f "$TEMP_OUT" "$TEMP_ERR" "$TEMP_PROMPT"
exit 1
