#!/bin/bash
set -euo pipefail

# Lobster Discord Relay
# Watches Lobster's inbox for result files from agents, posts to Discord #builds

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOME="${HOME:-/Users/$(whoami)}"

INBOX="$HOME/.myndaix/bridge/inbox/lobster"
PROCESSED="$HOME/.myndaix/bridge/processed"
LOG="$HOME/.myndaix/bridge/watchers/discord-relay.log"
LOCKDIR="$HOME/.myndaix/bridge/locks/discord-relay.lock"
DISCORD_CONFIG="$HOME/.openclaw/workspace/.discord-config.json"
BUILDS_CHANNEL="${DISCORD_BUILDS_CHANNEL:-}"
ALERTS_CHANNEL="${DISCORD_ALERTS_CHANNEL:-}"
MINI_CHANNEL="${DISCORD_MINI_CHANNEL:-}"
RECON_CHANNEL="${DISCORD_RECON_CHANNEL:-}"
COMMAND_CENTER_CHANNEL=$(ruby -rjson -e '
  cfg = JSON.parse(File.read(ARGV[0], encoding: "utf-8"))
  puts cfg.dig("channels", "command-center").to_s
' "$DISCORD_CONFIG" 2>/dev/null || echo "${DISCORD_COMMAND_CHANNEL:-}")
if [[ -z "$COMMAND_CENTER_CHANNEL" ]]; then
  COMMAND_CENTER_CHANNEL="${DISCORD_COMMAND_CHANNEL:-}"
fi

mkdir -p "$INBOX" "$PROCESSED" "$(dirname "$LOG")" "$(dirname "$LOCKDIR")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [relay] $*" >> "$LOG"
}

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$LOCKDIR/pid"
    trap 'rm -rf "$LOCKDIR"' EXIT
    return 0
  fi
  # Check for stale lock (>5 min)
  if [[ -f "$LOCKDIR/pid" ]]; then
    local old_pid
    old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [[ -n "$old_pid" ]] && ! kill -0 "$old_pid" 2>/dev/null; then
      rm -rf "$LOCKDIR"
      if mkdir "$LOCKDIR" 2>/dev/null; then
        echo "$$" > "$LOCKDIR/pid"
        trap 'rm -rf "$LOCKDIR"' EXIT
        return 0
      fi
    fi
  fi
  return 1
}

parse_frontmatter() {
  local file="$1"
  ruby -ryaml -rjson -rdate -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
    abort("no_frontmatter") unless m
    data = YAML.safe_load(m[1], permitted_classes: [Date, Time], aliases: false)
    abort("not_map") unless data.is_a?(Hash)
    puts JSON.generate(data)
  ' "$file" 2>/dev/null
}

json_get() {
  ruby -rjson -e '
    data = JSON.parse(ARGV[0])
    val = data[ARGV[1]]
    puts val.to_s unless val.nil?
  ' "$1" "$2" 2>/dev/null || echo ""
}

get_body() {
  local file="$1"
  ruby -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n.*?\n---\s*\n(.*)\z/m)
    puts m ? m[1].strip : ""
  ' "$file" 2>/dev/null || echo ""
}

get_body_or_full() {
  local file="$1"
  ruby -e '
    content = File.read(ARGV[0], encoding: "utf-8")
    m = content.match(/\A---\s*\n.*?\n---\s*\n(.*)\z/m)
    body = m ? m[1] : content
    puts body.strip
  ' "$file" 2>/dev/null || echo ""
}

format_digest_message() {
  local file="$1" fname="$2"
  ruby -e '
    file = ARGV[0]
    fname = ARGV[1]
    content = File.read(file, encoding: "utf-8")
    body = if (m = content.match(/\A---\s*\n.*?\n---\s*\n(.*)\z/m))
      m[1]
    else
      content
    end

    date_label = if (m = fname.match(/(\d{4})(\d{2})(\d{2})/))
      "#{m[1]}-#{m[2]}-#{m[3]}"
    else
      Time.now.strftime("%Y-%m-%d")
    end

    current_area = nil
    events = []
    body.each_line do |raw|
      line = raw.strip
      next if line.empty?
      if (m = line.match(/^##\s+(.+)$/))
        current_area = m[1].strip
        next
      end
      next unless line.start_with?("- **[") && line.include?("| [link](")
      m = line.match(/^- \*\*\[([^\]]+)\]\*\* \*\*(.+?)\*\* \| (.+)$/)
      next unless m

      score_raw = m[1].strip
      title = m[2].strip
      rest = m[3]
      parts = rest.split(" | ")
      when_value = parts[0]&.strip.to_s
      venue = parts[1]&.strip.to_s
      link_match = line.match(/\[link\]\((https?:\/\/[^)]+)\)/)
      url = link_match ? link_match[1] : ""

      score = score_raw.sub(%r{/10$}, "")
      when_value = "TBD" if when_value.empty?
      venue = "TBD" if venue.empty?
      next if url.empty?

      events << {
        title: title,
        score: score,
        when_value: when_value,
        venue: venue,
        area: current_area,
        url: url
      }
    end

    out = +"📅 **AI Events Digest — #{date_label}**\n"
    if events.empty?
      fallback = body.strip
      fallback = "No events were parsed from this digest." if fallback.empty?
      out << "\n" << fallback
      puts out
      exit 0
    end

    events.each do |ev|
      out << "\n**#{ev[:title]}**\n"
      out << "Score: #{ev[:score]}/10 | Date/Time: #{ev[:when_value]} | Venue: #{ev[:venue]}"
      if ev[:area] && !ev[:area].empty? && ev[:area] != "Unknown"
        out << " | Area: #{ev[:area]}"
      end
      out << "\nRSVP: #{ev[:url]}\n"
    end
    puts out
  ' "$file" "$fname" 2>/dev/null || echo ""
}

split_discord_chunks() {
  local message="$1"
  local max_chars="${2:-1900}"
  ruby -e '
    text = STDIN.read
    limit = ARGV[0].to_i
    chunks = []
    cur = +""

    text.each_line do |line|
      if cur.bytesize + line.bytesize <= limit
        cur << line
        next
      end

      if cur.empty?
        remaining = line.dup
        while remaining.bytesize > limit
          chunks << remaining.byteslice(0, limit)
          remaining = remaining.byteslice(limit, remaining.bytesize - limit)
        end
        cur = remaining
      else
        chunks << cur
        cur = +""
        if line.bytesize <= limit
          cur << line
        else
          remaining = line.dup
          while remaining.bytesize > limit
            chunks << remaining.byteslice(0, limit)
            remaining = remaining.byteslice(limit, remaining.bytesize - limit)
          end
          cur = remaining
        end
      end
    end
    chunks << cur unless cur.empty?
    chunks = [""] if chunks.empty?
    chunks.each { |c| STDOUT.write(c); STDOUT.write("\0") }
  ' "$max_chars" <<< "$message"
}

format_result_message() {
  local from="$1" subject="$2" validation="$3" branch="$4" engine="$5" body="$6"
  local icon
  case "$validation" in
    PASS)    icon="✅" ;;
    FAILED)  icon="❌" ;;
    TIMEOUT) icon="⏰" ;;
    REJECTED) icon="🚫" ;;
    *)       icon="📋" ;;
  esac

  local msg="${icon} **${from}** — ${subject}"
  msg+="\n**Status:** ${validation}"
  if [[ -n "$branch" && "$branch" != "n/a" ]]; then
    msg+="\n**Branch:** \`${branch}\`"
  fi
  if [[ -n "$engine" && "$engine" != "n/a" && "$engine" != "mack-watcher" ]]; then
    msg+="\n**Engine:** ${engine}"
  fi
  # Truncate body for Discord (max ~1800 chars to leave room)
  if [[ -n "$body" ]]; then
    local trimmed
    trimmed=$(echo "$body" | head -30 | cut -c1-1500)
    if [[ -n "$trimmed" ]]; then
      msg+="\n\`\`\`\n${trimmed}\n\`\`\`"
    fi
  fi
  echo -e "$msg"
}

format_alert_message() {
  local subject="$1" body="$2"
  local msg="🔔 **Alert:** ${subject}"
  if [[ -n "$body" ]]; then
    local trimmed
    trimmed=$(echo "$body" | head -20 | cut -c1-1000)
    msg+="\n${trimmed}"
  fi
  echo -e "$msg"
}

post_to_discord() {
  local channel="$1" message="$2"
  openclaw message send \
    --channel discord \
    --target "$channel" \
    --message "$message" \
    --silent 2>>"$LOG"
}

post_digest_to_discord() {
  local channel="$1" message="$2"
  local posted=0
  while IFS= read -r -d '' chunk; do
    [[ -z "$chunk" ]] && continue
    if ! post_to_discord "$channel" "$chunk"; then
      return 1
    fi
    posted=$((posted + 1))
  done < <(split_discord_chunks "$message" 1900)
  [[ $posted -gt 0 ]]
}

if ! acquire_lock; then
  log "Lock held, skipping"
  exit 0
fi

# Process all .md files in inbox
shopt -s nullglob
files=("$INBOX"/*.md)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

for file in "${files[@]}"; do
  fname=$(basename "$file")
  log "Processing: $fname"
  is_digest_file=0
  if [[ "$fname" == *ai-events* ]]; then
    is_digest_file=1
  fi

  frontmatter=$(parse_frontmatter "$file" || echo "")
  if [[ -z "$frontmatter" && $is_digest_file -eq 0 ]]; then
    log "No frontmatter in $fname, skipping"
    continue
  fi

  file_type=""
  from=""
  subject=""
  validation=""
  status=""
  branch=""
  engine=""
  if [[ -n "$frontmatter" ]]; then
    file_type=$(json_get "$frontmatter" "type")
    from=$(json_get "$frontmatter" "from")
    subject=$(json_get "$frontmatter" "subject")
    validation=$(json_get "$frontmatter" "validation")
    status=$(json_get "$frontmatter" "status")
    branch=$(json_get "$frontmatter" "branch")
    engine=$(json_get "$frontmatter" "engine")
  fi
  if [[ -z "$file_type" && $is_digest_file -eq 1 ]]; then
    file_type="digest"
  fi

  body=$(get_body_or_full "$file")
  if [[ -z "$validation" && -n "$status" ]]; then
    validation=$(echo "$status" | tr '[:lower:]' '[:upper:]')
  fi

  target_channel=""
  discord_msg=""

  case "$file_type" in
    result|response)
      # Agent results → their own channel. #builds only for agents without a dedicated channel.
      case "$from" in
        mini)  target_channel="$MINI_CHANNEL" ;;
        recon) target_channel="$RECON_CHANNEL" ;;
        *)     target_channel="$BUILDS_CHANNEL" ;;
      esac
      discord_msg=$(format_result_message "$from" "$subject" "$validation" "$branch" "$engine" "$body")
      ;;
    alert)
      # Alerts → #alerts
      target_channel="$ALERTS_CHANNEL"
      discord_msg=$(format_alert_message "$subject" "$body")
      ;;
    digest)
      # Event digests → #command-center with full detail
      target_channel="$COMMAND_CENTER_CHANNEL"
      discord_msg=$(format_digest_message "$file" "$fname")
      ;;
    *)
      log "Unknown type '$file_type' in $fname, skipping relay (will not archive)"
      continue
      ;;
  esac

  if [[ -n "$discord_msg" && -n "$target_channel" ]]; then
    if [[ "$file_type" == "digest" ]]; then
      post_digest_to_discord "$target_channel" "$discord_msg"
      post_ok=$?
    else
      post_to_discord "$target_channel" "$discord_msg"
      post_ok=$?
    fi

    if [[ $post_ok -eq 0 ]]; then
      log "Posted to Discord: $fname → channel $target_channel"
    else
      log "FAILED to post to Discord: $fname"
      # Don't archive on failure — retry next run
      continue
    fi
  fi

  # Archive after successful post
  local_target="$PROCESSED/$fname"
  if [[ -e "$local_target" ]]; then
    local_target="$PROCESSED/$(date -u '+%Y%m%d%H%M%S')-$fname"
  fi
  mv "$file" "$local_target"
  log "Archived: $fname"
done
