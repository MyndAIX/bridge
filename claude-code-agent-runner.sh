#!/bin/bash
# claude-code-agent-runner.sh — Codex-first, Claude Code+Ollama fallback agent runner
# Usage: claude-code-agent-runner.sh <agent-name> <task-file> <repo-path> <timeout> [sandbox-mode]
# sandbox-mode: "full" (default, can write files) or "read-only" (review only)
#
# Drop-in replacement for agent-runner.sh. Same interface, same output format.
# Difference: Uses Claude Code CLI + Ollama instead of custom ollama-agent-loop.py
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

AGENT="$1"
TASK_FILE="$2"
REPO="${3:-${DEFAULT_REPO:-$HOME/.openclaw/workspace}}"
TIMEOUT="${4:-300}"
SANDBOX="${5:-full}"
LOG="$HOME/.myndaix/bridge/watchers/agent-runner.log"

# Per-agent model selection (same as agent-runner.sh)
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

# Per-agent persona (replaces Modelfile SYSTEM prompt since Claude Code has its own system prompt)
case "$AGENT" in
  kilabz)
    PERSONA="You are KilaBz, a senior code reviewer.

Rules:
1. Only flag real issues: bugs, crashes, thread safety violations, security problems, performance issues
2. Do NOT suggest style changes, naming conventions, or nice-to-have improvements
3. For each issue found, use this format:
   **[SEVERITY: CRITICAL/HIGH/MED/LOW]** File:Line — Description
   **Why:** explanation
   **Fix:** concrete fix
4. If the code is correct and has no real issues, respond with: LGTM
5. Adapt language-specific review depth to the codebase: e.g. SwiftData thread-safety for iOS; goroutine leaks for Go; React rerender thrash for web.
6. Quote actual code from the files provided — never fabricate examples

"
    ;;
  antman)
    PERSONA="You are Antman, a builder agent. Write clean, working code that matches the conventions of the codebase under work. Read existing files before writing new ones. Match the project's idioms.

"
    ;;
  *)
    PERSONA=""
    ;;
esac

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT] $*" >> "$LOG"; }

# Read task content
TASK_CONTENT=$(cat "$TASK_FILE")

# --- Try 1: Codex CLI (same as agent-runner.sh) ---
log "Trying Codex CLI..."
TEMP_OUT="/tmp/cc-agent-out-$$.md"
TEMP_ERR="/tmp/cc-agent-err-$$.log"
TEMP_PROMPT="/tmp/cc-agent-prompt-$$.md"
echo "$TASK_CONTENT" > "$TEMP_PROMPT"

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
  log "Codex succeeded"
  echo "ENGINE=codex"
  cat "$TEMP_OUT"
  rm -f "$TEMP_OUT" "$TEMP_ERR" "$TEMP_PROMPT"
  exit 0
fi

# Codex failed — fall back to Claude Code + Ollama
log "Codex failed (exit=$CODEX_EXIT) — falling back to Claude Code + Ollama"
if [ -f "$TEMP_ERR" ]; then
  ERR_SUMMARY=$(tail -3 "$TEMP_ERR" 2>/dev/null | tr '\n' ' ')
  log "Codex stderr: $ERR_SUMMARY"
fi

# --- Try 2: Claude Code + Ollama ---
log "Falling back to Claude Code + Ollama ($OLLAMA_MODEL)..."
rm -f "$TEMP_OUT"

# Check Ollama is running
if ! curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
  log "Ollama not running — attempting start"
  brew services start ollama 2>/dev/null
  sleep 3
fi

# Check if primary model is available
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

# Configure Claude Code to use Ollama
export ANTHROPIC_BASE_URL="http://localhost:11434"
export ANTHROPIC_API_KEY="ollama"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Read task content for prompt
TASK_PROMPT=$(cat "$TEMP_PROMPT")

# Run Claude Code in print mode from the repo directory
log "Running Claude Code (model=$AVAILABLE_MODEL, sandbox=$SANDBOX)..."

# Build and run command — construct explicitly to handle multi-line persona
CC_CMD=(claude -p --model "$AVAILABLE_MODEL" --output-format text)

# Add persona as system prompt if agent has one
if [ -n "$PERSONA" ]; then
  CC_CMD+=(--system-prompt "$PERSONA")
fi

# Sandbox: restrict tools and permissions for read-only agents
if [ "$SANDBOX" = "read-only" ]; then
  CC_CMD+=(--permission-mode plan --tools "Read,Glob,Grep")
else
  CC_CMD+=(--dangerously-skip-permissions)
fi

# Add the actual task prompt
CC_CMD+=("$TASK_PROMPT")

# Run from repo directory with watchdog timeout (macOS has no `timeout` command)
( cd "$REPO" && "${CC_CMD[@]}" ) > "$TEMP_OUT" 2> "$TEMP_ERR" &
CC_PID=$!
( sleep "$TIMEOUT" && kill -TERM "$CC_PID" 2>/dev/null ) &
CC_WATCHDOG=$!
wait "$CC_PID" 2>/dev/null
CC_EXIT=$?
kill "$CC_WATCHDOG" 2>/dev/null || true
wait "$CC_WATCHDOG" 2>/dev/null || true

if [ "$CC_EXIT" -eq 124 ]; then
  log "Claude Code timed out after ${TIMEOUT}s"
elif [ "$CC_EXIT" -ne 0 ]; then
  log "Claude Code failed (exit=$CC_EXIT)"
  if [ -f "$TEMP_ERR" ]; then
    ERR_SUMMARY=$(tail -5 "$TEMP_ERR" 2>/dev/null | tr '\n' ' ')
    log "Claude Code stderr: $ERR_SUMMARY"
  fi
fi

if [ "$CC_EXIT" -eq 0 ] && [ -s "$TEMP_OUT" ]; then
  log "Claude Code + Ollama succeeded ($AVAILABLE_MODEL)"
  echo "ENGINE=claude-code:$AVAILABLE_MODEL"
  cat "$TEMP_OUT"
  rm -f "$TEMP_OUT" "$TEMP_ERR" "$TEMP_PROMPT"
  exit 0
fi

# --- Try 3: Fall back to custom ollama-agent-loop.py (safety net) ---
log "Claude Code failed — falling back to ollama-agent-loop.py..."
rm -f "$TEMP_OUT"

# Unset Claude Code overrides so they don't interfere
unset ANTHROPIC_BASE_URL
unset ANTHROPIC_API_KEY

AGENT_LOOP="$HOME/.myndaix/bridge/ollama-agent-loop.py"

# Pre-read files for prompt injection (helps models that struggle with tool calling)
ENRICHED_PROMPT="/tmp/cc-agent-enriched-$$.md"
python3 "$HOME/.myndaix/bridge/ollama-enrich-prompt.py" "$REPO" < "$TEMP_PROMPT" > "$ENRICHED_PROMPT" 2>/dev/null
if [ -s "$ENRICHED_PROMPT" ]; then
  INJECT_PROMPT="$ENRICHED_PROMPT"
  INJECTED_SIZE=$(wc -c < "$ENRICHED_PROMPT")
  log "Enriched prompt with file contents ($INJECTED_SIZE bytes)"
else
  INJECT_PROMPT="$TEMP_PROMPT"
fi

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

log "All engines failed (Codex=$CODEX_EXIT, ClaudeCode=$CC_EXIT, Ollama=$OLLAMA_EXIT)"
echo "ENGINE=none"
echo "All engines failed: Codex, Claude Code, and Ollama."
[ -f "$TEMP_ERR" ] && cat "$TEMP_ERR"
rm -f "$TEMP_OUT" "$TEMP_ERR" "$TEMP_PROMPT"
exit 1
