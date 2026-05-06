#!/bin/bash
# scan-inbox.sh — Bridge Inbox Injection Scanner
# Validates .md files for prompt injection patterns before watcher processing
# Usage: scan-inbox.sh <file_path> [agent_name]
# Exit 0 = SAFE, Exit 1 = QUARANTINED

set -uo pipefail

# --- Configuration ---
QUARANTINE_DIR="$HOME/.myndaix/bridge/inbox/quarantine"
QUARANTINE_LOG="/tmp/bridge-quarantine.log"
WHITELIST_FILE="$HOME/.myndaix/bridge/scripts/injection-whitelist.txt"
MAX_FILE_SIZE=1048576  # 1MB limit

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- Args ---
if [[ $# -lt 1 ]]; then
    echo -e "${RED}FAIL${NC}: No file specified"
    echo "Usage: scan-inbox.sh <file_path> [agent_name]"
    exit 1
fi

FILE_PATH="$1"
AGENT_NAME="${2:-unknown}"
FILENAME=$(basename "$FILE_PATH")

if [[ ! -f "$FILE_PATH" ]]; then
    echo -e "${RED}FAIL${NC}: File not found: $FILE_PATH"
    exit 1
fi

# --- Ensure quarantine directory exists ---
mkdir -p "$QUARANTINE_DIR"

# --- Logging ---
log_event() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $AGENT_NAME: $FILENAME - $message" >> "$QUARANTINE_LOG"
}

# --- Extract file content ---
get_frontmatter() {
    awk '/^---$/{if(++c==1){next}if(c==2){exit}}c==1{print}' "$FILE_PATH"
}

get_body() {
    awk '/^---$/{if(++c==2){p=1;next}}p{print}' "$FILE_PATH"
}

# --- Whitelist check ---
is_whitelisted() {
    local pattern="$1"
    if [[ -f "$WHITELIST_FILE" ]]; then
        while IFS= read -r whitelist_entry; do
            # Skip comments and empty lines
            [[ -z "$whitelist_entry" || "$whitelist_entry" =~ ^[[:space:]]*# ]] && continue
            if echo "$pattern" | grep -qE "$whitelist_entry"; then
                return 0
            fi
        done < "$WHITELIST_FILE"
    fi
    return 1
}

# --- Pattern checking functions ---
# Each function returns 0 if pattern found (unsafe), 1 if not found (safe)

check_system_override() {
    local content="$1"
    echo "$content" | grep -qEi 'system:\s*(ignore|override)|ignore\s+(all\s+)?(previous\s+)?(instructions|commands|prompts|rules)|override\s+(all\s+)?(system\s+)?(instructions|commands|prompts|rules)'
}

check_roleplay() {
    local content="$1"
    echo "$content" | grep -qEi '(pretend|act\s+like|you\s+are\s+now|roleplay|assume\s+the\s+role)(\s+that)?\s+you\s+(are|re)|imagine\s+you\s+are'
}

check_tool_injection() {
    local content="$1"
    echo "$content" | grep -qEi '<(antml:)?function_calls>|<invoke\s+name=|function_calls.*invoke|<parameter>'
}

check_encoding() {
    local content="$1"
    echo "$content" | grep -qEi '(base64|atob|btoa|eval\(|exec\()|\\x[0-9a-f][0-9a-f][0-9a-f]|%[0-9a-f][0-9a-f]%[0-9a-f][0-9a-f]'
}

check_command_injection() {
    local content="$1"
    echo "$content" | grep -qEi '\$\([^)]+\)|`[^`]+`|exec\s+[^[:space:]]+|system\s*\([^)]+\)|shell_exec|passthru|popen\s*\('
}

check_escape_sequences() {
    local content="$1"
    echo "$content" | grep -qEi '\\u[0-9a-f][0-9a-f][0-9a-f][0-9a-f]|\\x[0-9a-f][0-9a-f]|\\[0-7][0-7][0-7]|&#x[0-9a-f]+;'
}

check_instruction_termination() {
    local content="$1"
    echo "$content" | grep -qEi 'end\s+of\s+(prompt|instruction)|stop\s+(all\s+)?(instruction|processing)|ignore\s+everything\s+(above|before|prior)|start\s+over|new\s+session'
}

check_context_overflow() {
    local content="$1"
    echo "$content" | grep -qE '\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*|################|================|----------------|\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.'
}

check_agent_confusion() {
    local content="$1"
    echo "$content" | grep -qEi 'you\s+are\s+(claude|gpt|chatgpt|openai)|switch\s+to\s+(claude|gpt)|i\s+am\s+(claude|gpt)|(claude|gpt|ai)\s+mode'
}

check_memory_manipulation() {
    local content="$1"
    echo "$content" | grep -qEi 'forget\s+(everything|all|previous|context)|clear\s+(memory|history|context|state)|reset\s+(state|context|memory)'
}

check_file_manipulation() {
    local content="$1"
    echo "$content" | grep -qEi '\.\./|/etc/|/var/log|/tmp/[^[:space:]]+\.[a-z][a-z][a-z]?[a-z]?|rm\s+-rf|chmod\s+(777|666)|sudo\s+'
}

check_network_access() {
    local content="$1"
    # Check for HTTP(S) URLs that aren't in our whitelist
    if echo "$content" | grep -qEi 'https?://[^[:space:]]+'; then
        # Check if it's NOT a whitelisted domain
        if ! echo "$content" | grep -qEi 'https?://(github\.com|anthropic\.com|claude\.com)'; then
            return 0  # Found suspicious URL
        fi
    fi
    # Check for other network access patterns
    echo "$content" | grep -qEi 'curl\s+|wget\s+|fetch\s*\(|XMLHttpRequest|ajax'
}

# --- Main quarantine function ---
quarantine_file() {
    local reason="$1"
    local detected_pattern="$2"

    # Create unique quarantine filename
    local quarantine_path="$QUARANTINE_DIR/$FILENAME"
    local counter=1
    while [[ -f "$quarantine_path" ]]; do
        local name_no_ext="${FILENAME%.*}"
        local ext="${FILENAME##*.}"
        if [[ "$name_no_ext" == "$FILENAME" ]]; then
            quarantine_path="$QUARANTINE_DIR/${FILENAME}_${counter}"
        else
            quarantine_path="$QUARANTINE_DIR/${name_no_ext}_${counter}.${ext}"
        fi
        counter=$((counter + 1))
    done

    # Move file to quarantine
    mv "$FILE_PATH" "$quarantine_path"

    # Log the event
    log_event "QUARANTINE" "$reason - Pattern: $detected_pattern"

    # Send alert if OpenClaw is available
    if command -v openclaw >/dev/null 2>&1; then
        openclaw message send --channel discord -t "${DISCORD_COMMAND_CHANNEL:-}" \
            -m "🚨 **Bridge Security Alert:** File quarantined: \`$FILENAME\` - $reason" \
            --silent 2>/dev/null &
    fi

    echo -e "${RED}QUARANTINED${NC}: $FILENAME"
    echo "  Reason: $reason"
    echo "  Pattern: $detected_pattern"
    echo "  Location: $quarantine_path"
    return 1
}

# --- Main scanning logic ---

# Check file size first
FILE_SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ')
if (( FILE_SIZE > MAX_FILE_SIZE )); then
    quarantine_file "File exceeds size limit" "${FILE_SIZE} bytes > ${MAX_FILE_SIZE} bytes"
    exit 1
fi

# Extract content sections
FRONTMATTER=$(get_frontmatter)
BODY=$(get_body)

# Skip completely empty files
if [[ -z "$FRONTMATTER" && -z "$BODY" ]]; then
    log_event "SKIP" "empty file"
    echo -e "${YELLOW}SKIPPED${NC}: $FILENAME (empty)"
    exit 0
fi

# Check for binary content
if file "$FILE_PATH" | grep -qi binary; then
    quarantine_file "Binary content detected" "file command detected binary"
    exit 1
fi

# Define pattern checks with names
PATTERN_CHECKS=(
    "system_override:check_system_override"
    "roleplay_attack:check_roleplay"
    "tool_injection:check_tool_injection"
    "encoding_attack:check_encoding"
    "command_injection:check_command_injection"
    "escape_sequences:check_escape_sequences"
    "instruction_termination:check_instruction_termination"
    "context_overflow:check_context_overflow"
    "agent_confusion:check_agent_confusion"
    "memory_manipulation:check_memory_manipulation"
    "file_manipulation:check_file_manipulation"
    "network_access:check_network_access"
)

# Scan frontmatter
if [[ -n "$FRONTMATTER" ]]; then
    for pattern_check in "${PATTERN_CHECKS[@]}"; do
        IFS=':' read -r pattern_name check_function <<< "$pattern_check"
        if $check_function "$FRONTMATTER"; then
            detected_text=$(echo "$FRONTMATTER" | grep -Ei "$(echo "$pattern_name" | tr '_' ' ')" | head -1 | cut -c1-50)
            if ! is_whitelisted "$detected_text"; then
                quarantine_file "Injection pattern detected in frontmatter" "$pattern_name: $detected_text"
                exit 1
            fi
        fi
    done

    # Check for malformed YAML
    if echo "$FRONTMATTER" | grep -qE ':\s*\||>\s*[^[:space:]]|^\s\s\s\s\s\s\s\s\s\s\s\s\s\s\s\s\s\s\s\s'; then
        quarantine_file "Suspicious YAML structure" "excessive nesting or malformed structure"
        exit 1
    fi
fi

# Scan body
if [[ -n "$BODY" ]]; then
    for pattern_check in "${PATTERN_CHECKS[@]}"; do
        IFS=':' read -r pattern_name check_function <<< "$pattern_check"
        if $check_function "$BODY"; then
            detected_text=$(echo "$BODY" | grep -Ei "$(echo "$pattern_name" | tr '_' ' ')" | head -1 | cut -c1-50)
            if ! is_whitelisted "$detected_text"; then
                quarantine_file "Injection pattern detected in body" "$pattern_name: $detected_text"
                exit 1
            fi
        fi
    done
fi

# Success - file is clean
log_event "SAFE" "passed all injection pattern checks"
echo -e "${GREEN}SAFE${NC}: $FILENAME (${FILE_SIZE} bytes)"
exit 0