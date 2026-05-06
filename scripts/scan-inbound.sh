#!/bin/bash
# scan-inbound.sh - Security scanner for MyndAIX bridge inbound messages
# Scans .md files for prompt injection patterns before watcher processing
#
# Usage: scan-inbound.sh <file_path>
# Exit codes: 0=clean, 1=quarantined, 2=error

set -euo pipefail

# Configuration
BRIDGE_DIR="${HOME}/.myndaix/bridge"
PATTERNS_FILE="${BRIDGE_DIR}/patterns.yaml"
SECURITY_LOG="${BRIDGE_DIR}/state/security-scan.log"
DEAD_LETTER_DIR="${BRIDGE_DIR}/dead-letter"
QUARANTINE_DIR="${BRIDGE_DIR}/quarantine"

# Ensure required directories exist
mkdir -p "$(dirname "$SECURITY_LOG")" "$DEAD_LETTER_DIR" "$QUARANTINE_DIR"

# Logging function
log_security_event() {
  local level="$1"
  local message="$2"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  echo "[$timestamp] [$level] $message" | tee -a "$SECURITY_LOG"
}

# Check if file content matches any pattern using simplified Python script
check_patterns() {
  local file_path="$1"

  # Create a temporary Python script for pattern matching
  local python_script=$(mktemp)
  cat > "$python_script" << 'EOF'
import yaml
import sys
import re
import os

patterns_file = sys.argv[1]
content_file = sys.argv[2]

try:
    # Load patterns
    with open(patterns_file, 'r') as f:
        data = yaml.safe_load(f)

    # Load content
    with open(content_file, 'r') as f:
        content = f.read()

    matches = []
    quarantine_required = False

    # Check all pattern categories
    categories = [
        'instructionOverridePatterns',
        'rolePlayingPatterns',
        'encodingObfuscationPatterns',
        'contextManipulationPatterns',
        'instructionSmugglingPatterns',
        'bridgeSpecificPatterns'
    ]

    for category in categories:
        if category in data:
            patterns = data[category]
            for pattern_obj in patterns:
                if isinstance(pattern_obj, dict):
                    pattern = pattern_obj.get('pattern', '')
                    reason = pattern_obj.get('reason', '')
                    severity = pattern_obj.get('severity', '')

                    if pattern:
                        try:
                            if re.search(pattern, content):
                                matches.append({
                                    'category': category,
                                    'pattern': pattern,
                                    'reason': reason,
                                    'severity': severity
                                })
                                if severity in ['high', 'medium']:
                                    quarantine_required = True
                        except re.error as e:
                            print(f"REGEX_ERROR: {pattern} - {e}", file=sys.stderr)

    # Output results
    print(f"MATCHES:{len(matches)}")
    print(f"QUARANTINE:{quarantine_required}")
    for match in matches:
        print(f"MATCH:{match['category']}|{match['severity']}|{match['reason']}")

except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)
EOF

  # Run Python script and capture output
  local output
  local python_exit_code=0

  output=$(python3 "$python_script" "$PATTERNS_FILE" "$file_path" 2>&1) || python_exit_code=$?
  rm -f "$python_script"

  if [ $python_exit_code -ne 0 ]; then
    log_security_event "ERROR" "Python script failed: $output"
    return 2
  fi

  # Parse output
  local matches=0
  local quarantine_required=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^MATCHES:([0-9]+) ]]; then
      matches="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^QUARANTINE:(true|false|True|False) ]]; then
      quarantine_required="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^MATCH: ]]; then
      log_security_event "MATCH" "File: $file_path | $line"
    fi
  done <<< "$output"

  if [ "$matches" -gt 0 ]; then
    if [ "$quarantine_required" = "true" ] || [ "$quarantine_required" = "True" ]; then
      return 1  # Quarantine required
    else
      return 0  # Low severity matches only
    fi
  else
    return 0    # Clean file
  fi
}

# Quarantine file
quarantine_file() {
  local file_path="$1"
  local timestamp=$(date +"%Y%m%d_%H%M%S")
  local filename=$(basename "$file_path")
  local quarantine_path="${DEAD_LETTER_DIR}/${timestamp}_${filename}"

  # Copy to dead-letter (preserve original for investigation)
  if cp "$file_path" "$quarantine_path" 2>/dev/null; then
    # Remove from original location
    rm "$file_path" 2>/dev/null || true
    log_security_event "QUARANTINE" "File moved to dead-letter: $file_path -> $quarantine_path"
    return 0
  else
    log_security_event "ERROR" "Failed to quarantine file: $file_path"
    return 1
  fi
}

# Main scanning logic
main() {
  local file_path="$1"

  # Validate input
  if [ ! -f "$file_path" ]; then
    log_security_event "ERROR" "File not found: $file_path"
    exit 2
  fi

  # Check if it's a markdown file
  if [[ ! "$file_path" == *.md ]]; then
    log_security_event "SKIP" "Non-markdown file: $file_path"
    exit 0
  fi

  # Skip messages from trusted internal agents (never quarantine internal comms)
  TRUSTED_SENDERS="lobster mack mini antman kilabz oracle recon harley jefe cli"
  local sender
  sender=$(grep -m1 '^from:' "$file_path" 2>/dev/null | sed 's/from: *//' | tr -cd 'a-zA-Z0-9._-')
  if echo "$TRUSTED_SENDERS" | grep -Fqw "$sender" 2>/dev/null; then
    log_security_event "TRUSTED" "Skipping scan for trusted sender: $sender ($file_path)"
    exit 0
  fi

  # Skip syncthing temp files
  local filename=$(basename "$file_path")
  if [[ "$filename" == .* ]] || [[ "$filename" == *"~syncthing~"* ]] || [[ "$filename" == *".syncthing."* ]]; then
    log_security_event "SKIP" "Temporary file: $file_path"
    exit 0
  fi

  # Check if patterns file exists
  if [ ! -f "$PATTERNS_FILE" ]; then
    log_security_event "ERROR" "Patterns file not found: $PATTERNS_FILE"
    exit 2
  fi

  log_security_event "SCAN_START" "Scanning file: $file_path"

  # Perform pattern matching
  local check_result
  set +e  # Temporarily disable exit on error
  check_patterns "$file_path"
  check_result=$?
  set -e  # Re-enable exit on error


  case $check_result in
    0)
      log_security_event "SCAN_RESULT" "File cleared: $file_path"
      exit 0
      ;;
    1)
      log_security_event "SCAN_RESULT" "File flagged for quarantine: $file_path"
      if quarantine_file "$file_path"; then
        exit 1  # Successfully quarantined
      else
        exit 2  # Quarantine failed
      fi
      ;;
    *)
      log_security_event "ERROR" "Pattern check failed: $file_path"
      exit 2
      ;;
  esac
}

# Ensure we have required dependencies
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 required for pattern matching" >&2
  exit 2
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "ERROR: PyYAML required for pattern parsing" >&2
  echo "Install with: pip3 install PyYAML" >&2
  exit 2
fi

# Run main function with provided arguments
if [ $# -eq 0 ]; then
  echo "Usage: $0 <file_path>"
  echo "Scans a markdown file for prompt injection patterns"
  exit 2
fi

main "$@"