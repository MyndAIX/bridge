#!/bin/bash
# cleanup-worktrees.sh — Prune stale worktrees daily
set -uo pipefail
export HOME="${HOME:-/Users/$(whoami)}"
LOG="$HOME/.myndaix/bridge/watchers/cleanup.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $*" >> "$LOG"; }

# Prune git worktrees in all repos.
# WORKTREE_REPOS is a space-separated env var (set in ~/.myndaix/.secrets);
# defaults to just the OpenClaw workspace.
WORKTREE_REPOS="${WORKTREE_REPOS:-$HOME/.openclaw/workspace}"

for REPO in $WORKTREE_REPOS; do
  [ -d "$REPO/.git" ] || continue
  PRUNED=$(git -C "$REPO" worktree prune 2>&1)
  [ -n "$PRUNED" ] && log "Pruned worktrees in $REPO: $PRUNED"
done

# Remove stale worktree dirs older than 24 hours
for DIR in /tmp/mini-worktrees /tmp/antman-worktrees /tmp/kilabz-worktrees /tmp/recon-worktrees; do
  [ -d "$DIR" ] || continue
  find "$DIR" -maxdepth 1 -type d -mtime +0 -not -name "$(basename $DIR)" | while read d; do
    rm -rf "$d"
    log "Removed stale worktree: $d"
  done
done

log "Cleanup complete"
