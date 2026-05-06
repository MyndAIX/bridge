#!/bin/bash
# Log rotation for MyndAIX watcher logs
# Rotates any log over 100KB — keeps one .bak copy

MAX_SIZE=102400  # 100KB in bytes

LOGS=(
  "$HOME/.myndaix/bridge/watchers/mini-watcher.log"
  "$HOME/.myndaix/bridge/watchers/recon-watcher.log"
  "$HOME/.myndaix/bridge/watchers/antman-watcher.log"
  "$HOME/.myndaix/bridge/watchers/kilabz-watcher.log"
  "$HOME/.myndaix/bridge/watchers/lobster-health.log"
  "$HOME/.myndaix/bridge/watchers/launchd.out.log"
  "/tmp/antman-watcher-stdout.log"
  "/tmp/antman-watcher-stderr.log"
  "/tmp/mini-watcher-stdout.log"
  "/tmp/mini-watcher-stderr.log"
  "/tmp/recon-watcher-stdout.log"
  "/tmp/recon-watcher-stderr.log"
  "/tmp/kilabz-watcher-stdout.log"
  "/tmp/kilabz-watcher-stderr.log"
  "$HOME/.myndaix/bridge/watchers/discord-relay.log"
  "$HOME/.myndaix/bridge/watchers/watcher.log"
)

for log in "${LOGS[@]}"; do
  if [ -f "$log" ]; then
    size=$(stat -f%z "$log" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_SIZE" ]; then
      cp "$log" "${log}.bak"
      : > "$log"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated (was ${size} bytes)" > "$log"
    fi
  fi
done
