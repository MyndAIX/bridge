#!/bin/bash
# format-validator.sh — Strict format validation for KilaBz/Codex review output
# Replaces loose evidence regex with dedicated validator per MX-FORMAT-VALIDATOR.md
#
# Usage: source this file, then call validate_kilabz_result()
# Returns 0 on valid format, 1 on validation failure with error message

FORMAT_VALIDATOR_VERSION="1.0.0"

# Feature flag for fallback to loose regex (default: strict mode)
KILABZ_STRICT_VALIDATION="${KILABZ_STRICT_VALIDATION:-true}"

# ============================================================
# validate_kilabz_result(output_file, expected_count)
#   Strict validation of KilaBz/Codex review output format.
#   Returns 0 if format is valid, 1 if invalid.
#   Error message written to stderr on failure.
# ============================================================
validate_kilabz_result() {
  local output_file="$1"
  local expected_count="${2:-0}"

  if [[ ! -f "$output_file" ]]; then
    echo "output file not found: $output_file"
    return 1
  fi

  # Check 1: Overall verdict line must be present and valid
  if ! grep -Eq '^OVERALL VERDICT: (PASS|FAIL)$' "$output_file"; then
    echo "missing or invalid 'OVERALL VERDICT: PASS|FAIL' line"
    return 1
  fi

  # Check 2: Must have FINDINGS: section
  if ! grep -q '^FINDINGS:' "$output_file"; then
    echo "missing 'FINDINGS:' section header"
    return 1
  fi

  # Check 3: Strict evidence format validation
  local findings_count=0
  local line_num=0
  local in_findings_section=false

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Track if we're in the FINDINGS section.
    # Reset findings_count on each FINDINGS: marker — watchers capture both the
    # prompt template (which has its own FINDINGS:) and the model output (which
    # also has FINDINGS:). The LAST block is the real one; we count only it.
    if [[ "$line" == "FINDINGS:" ]]; then
      in_findings_section=true
      findings_count=0
      continue
    fi

    # Skip empty lines and lines outside FINDINGS section
    [[ -z "$line" || "$in_findings_section" != "true" ]] && continue

    # NOTE: previous versions broke on any "ALL CAPS:" line as a section
    # boundary, but real KilaBz files contain many such lines in the prompt
    # context (IMPORTANT:, SUBJECT:, REVIEW TYPE:, RUBRIC FILE:, etc.) that
    # appear AFTER the template FINDINGS: but BEFORE the real findings block.
    # We rely on FINDINGS: marker resets above to ensure only the last block's
    # findings are counted. Non-findings lines are silently skipped below.

    # Skip prompt-template lines that contain literal format placeholders.
    # KilaBz/Codex watchers capture both the prompt template (with examples like
    # "[PASS|FAIL] <criterion> | Evidence: <relative/path.ext:line> | Reason: <one short sentence>")
    # AND the model output. Template lines must not be counted as findings AND
    # must not trigger the "wrong format" elif branch below (they DO start with
    # a number). Surfaced 2026-05-07 by test-real-kilabz-{1..5}.txt fixtures.
    if [[ "$line" == *"PASS|FAIL"* ]] || \
       [[ "$line" == *"<criterion>"* ]] || \
       [[ "$line" == *"<relative/path"* ]] || \
       [[ "$line" == *"<one short sentence>"* ]]; then
      continue
    fi

    # Check if this line matches the strict finding format
    if [[ "$line" =~ ^[0-9]+\.\ \[(PASS|FAIL)\]\ .+\ \|\ Evidence:\ .+\ \|\ Reason:\ .+ ]]; then
      findings_count=$((findings_count + 1))

      # Extract and validate the evidence portion
      local evidence_part
      evidence_part=$(echo "$line" | sed -n 's/.*| Evidence: \(.*\) | Reason:.*/\1/p')

      if [[ -z "$evidence_part" ]]; then
        echo "finding on line $line_num has empty evidence section"
        return 1
      fi

      # Evidence must include file path and line number (file:line format)
      if ! [[ "$evidence_part" =~ ^[^[:space:]]+:[0-9]+.*$ ]]; then
        echo "finding on line $line_num has invalid evidence format - must be 'file:line' (got: '$evidence_part')"
        return 1
      fi

      # Extract and validate reason portion
      local reason_part
      reason_part=$(echo "$line" | sed -n 's/.* | Reason: \(.*\)$/\1/p')

      if [[ -z "$reason_part" ]]; then
        echo "finding on line $line_num has empty reason section"
        return 1
      fi

    elif [[ "$line" =~ ^[0-9]+\.[[:space:]]*\[(PASS|FAIL)\] ]]; then
      # Line has [PASS]/[FAIL] marker but doesn't match full strict format
      # (likely missing Evidence: or Reason: sections, or malformed pipes).
      # Numbered lines WITHOUT [PASS|FAIL] markers (e.g., rubric criteria
      # listed in the prompt) are silently skipped — they're not findings.
      echo "finding on line $line_num doesn't match required format: '$line'"
      echo "expected: 'N. [PASS|FAIL] <criterion> | Evidence: <file:line> | Reason: <reason>'"
      return 1
    fi

  done < "$output_file"

  # Check 4: Must have at least one finding
  if (( findings_count == 0 )); then
    echo "no findings found in required format"
    return 1
  fi

  # Check 5: Expected count validation (if specified)
  if (( expected_count > 0 && findings_count < expected_count )); then
    echo "insufficient findings: expected at least $expected_count, got $findings_count"
    return 1
  fi

  # Check 6: Verdict consistency - if any finding is FAIL, overall verdict must be FAIL
  # Use the LAST real verdict line (PASS or FAIL exact match), not the template
  # placeholder "OVERALL VERDICT: PASS|FAIL" that may appear earlier in the file.
  local verdict
  verdict=$(grep -E '^OVERALL VERDICT: (PASS|FAIL)$' "$output_file" | tail -1 | awk '{print $NF}')

  if [[ "$verdict" == "PASS" ]]; then
    # Count [FAIL] findings, but skip template lines containing "PASS|FAIL".
    local fail_count
    fail_count=$(grep -E '^\s*[0-9]+\.\s*\[FAIL\]' "$output_file" | grep -vc 'PASS|FAIL' || echo 0)
    if (( fail_count > 0 )); then
      echo "verdict consistency error: OVERALL VERDICT is PASS but found $fail_count FAIL findings"
      return 1
    fi
  fi

  return 0
}

# ============================================================
# validate_kilabz_result_fallback(output_file, expected_count)
#   Fallback to loose regex validation (original implementation)
#   Used when KILABZ_STRICT_VALIDATION=false
# ============================================================
validate_kilabz_result_fallback() {
  local output_file="$1"
  local expected_count="${2:-0}"

  if ! grep -Eq '^OVERALL VERDICT: (PASS|FAIL)$' "$output_file"; then
    echo "missing or invalid 'OVERALL VERDICT: PASS|FAIL' line"
    return 1
  fi

  local findings_count
  # Original loose evidence regex - any non-empty content between Evidence: and | Reason:
  findings_count=$(grep -Ec '^[0-9]+\.\s+\[(PASS|FAIL)\]\s+.+\|\s+Evidence:\s+.+\s+\|\s+Reason:\s+.+' "$output_file" || echo 0)

  if (( findings_count == 0 )); then
    echo "no findings matched required '[PASS|FAIL] ... | Evidence: file:line | Reason: ...' format"
    return 1
  fi

  if (( expected_count > 0 && findings_count < expected_count )); then
    echo "insufficient findings: expected at least $expected_count, got $findings_count"
    return 1
  fi

  return 0
}

# ============================================================
# validate_kilabz_output(output_file, expected_count)
#   Main entry point - chooses strict or fallback validation based on feature flag
# ============================================================
validate_kilabz_output() {
  local output_file="$1"
  local expected_count="${2:-0}"

  if [[ "${KILABZ_STRICT_VALIDATION:-true}" == "true" ]]; then
    validate_kilabz_result "$output_file" "$expected_count"
  else
    validate_kilabz_result_fallback "$output_file" "$expected_count"
  fi
}

# ============================================================
# route_to_quarantine(task_name, validation_error, original_output)
#   Route failed validation to quarantine directory instead of result inbox
# ============================================================
route_to_quarantine() {
  local task_name="$1"
  local validation_error="$2"
  local original_output="$3"
  local quarantine_dir="${HOME}/.myndaix/bridge/quarantine"

  mkdir -p "$quarantine_dir"

  local timestamp
  timestamp=$(date '+%Y%m%d%H%M%S')
  local quarantine_file="$quarantine_dir/${timestamp}-${task_name}-format-validation-failed.md"

  {
    echo "---"
    echo "type: quarantine"
    echo "reason: format_validation_failed"
    echo "agent: kilabz"
    echo "task: $task_name"
    echo "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "validation_error: \"$(_sanitize_yaml "$validation_error")\""
    echo "---"
    echo ""
    echo "## Format Validation Failed"
    echo ""
    echo "**Error:** $validation_error"
    echo ""
    echo "**Expected format:**"
    echo "```"
    echo "OVERALL VERDICT: PASS|FAIL"
    echo "FINDINGS:"
    echo "1. [PASS|FAIL] <criterion> | Evidence: <file:line> | Reason: <reason>"
    echo "2. [PASS|FAIL] <criterion> | Evidence: <file:line> | Reason: <reason>"
    echo "```"
    echo ""
    echo "**Original output:**"
    echo "```"
    echo "$original_output"
    echo "```"
  } > "$quarantine_file"

  log "Quarantined failed validation: $quarantine_file"
  echo "$quarantine_file"
}

# Helper function for YAML sanitization (if not already loaded from common.sh)
if ! declare -f _sanitize_yaml >/dev/null 2>&1; then
  _sanitize_yaml() {
    local val="$1"
    val="${val//$'\n'/ }"
    val="${val//$'\r'/}"
    val="${val//\"/\\\"}"
    printf '%s' "$val"
  }
fi

# Defensive fallback: route_to_quarantine calls log(). When format-validator.sh
# is sourced standalone (tests, ad-hoc invocations), common.sh's log() may not
# exist. Define a stderr fallback so route_to_quarantine doesn't silently noop.
if ! declare -f log >/dev/null 2>&1; then
  log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [format-validator] $*" >&2
  }
fi


# Defensive log() fallback if sourced standalone (e.g. tests, watchers that forget common.sh)
if ! declare -f log >/dev/null 2>&1; then
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fi
