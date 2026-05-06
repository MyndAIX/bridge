#!/bin/bash
# tts-bridge.sh — Watches for OpenClaw TTS audio files
# Primary: SSH direct push to peer machine for instant playback
# Fallback: Copy to bridge/audio/ for Syncthing sync

export HOME="${HOME:-/Users/$(whoami)}"
export BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"

BRIDGE_AUDIO="$BRIDGE_DIR/audio"
TTS_TMP="/tmp/openclaw"
LOG="$BRIDGE_AUDIO/bridge.log"

# Peer machine SSH details (configurable; set in ~/.myndaix/.secrets)
MB_USER="${MACBOOK_SSH_USER:-stevenfernandez}"
MB_LAN="${MACBOOK_LAN_IP:-}"
MB_TAILSCALE="${MACBOOK_TAILSCALE_IP:-}"
MB_AUDIO="$BRIDGE_DIR/audio"
MB_PLAYED="$BRIDGE_DIR/audio/played"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

ssh_push() {
  local file="$1"
  local basename="$(basename "$file")"
  local wav_tmp="/tmp/openclaw/push_${RANDOM}.wav"

  # Convert OGG→WAV for MacBook afplay compatibility
  if [[ "$file" == *.ogg ]]; then
    if ffmpeg -y -loglevel quiet -i "$file" -ar 44100 -ac 1 "$wav_tmp" 2>/dev/null; then
      basename="${basename%.ogg}.wav"
    else
      log "CONVERT_FAIL: could not convert $basename to WAV"
      rm -f "$wav_tmp"
      return 1
    fi
    local push_file="$wav_tmp"
  else
    local push_file="$file"
  fi

  # Sanitize basename for safe use in remote shell commands
  local safe_basename
  safe_basename="$(printf '%q' "$basename")"

  # Try LAN first, then Tailscale
  local host=""
  for try_host in "$MB_LAN" "$MB_TAILSCALE"; do
    if scp -o ConnectTimeout=2 -o BatchMode=yes "$push_file" "${MB_USER}@${try_host}:${MB_AUDIO}/${safe_basename}" 2>/dev/null; then
      host="$try_host"
      break
    fi
  done

  if [[ -n "$host" ]]; then
    ssh -o ConnectTimeout=2 -o BatchMode=yes "${MB_USER}@${host}" \
      "mkdir -p ${MB_PLAYED}; afplay ${MB_AUDIO}/${safe_basename} && mv ${MB_AUDIO}/${safe_basename} ${MB_PLAYED}/" 2>/dev/null &
    log "SSH_PUSH: $basename → MacBook@${host} (instant)"
    rm -f "$wav_tmp" 2>/dev/null
    return 0
  else
    log "SSH_FAIL: $basename — MacBook unreachable (LAN+Tailscale)"
    rm -f "$wav_tmp" 2>/dev/null
    return 1
  fi
}

# fswatch for new audio files in /tmp/openclaw
fswatch -0 --event Created "$TTS_TMP" 2>/dev/null | while IFS= read -r -d '' file; do
  case "$file" in
    */voice-*.ogg|*/voice-*.mp3|*/voice-*.wav|*/lobster-*.ogg|*/lobster-*.mp3)
      ts=$(date '+%Y%m%d-%H%M%S')
      ext="${file##*.}"
      dest="$BRIDGE_AUDIO/lobster-${ts}.${ext}"

      # Always copy to bridge (archive)
      cp "$file" "$dest" 2>/dev/null && log "COPIED: $(basename "$file") → $(basename "$dest")"

      # SSH direct push for instant playback
      ssh_push "$dest"
      ;;
  esac
done
