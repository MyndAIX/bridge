#!/bin/bash
# Test suite for KilaBz format validator
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/../../watchers/lib" && pwd)"

# Source the format validator
source "$LIB_DIR/format-validator.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
log_test() {
  echo "[TEST] $*"
}

run_test() {
  local test_name="$1"
  local test_file="$2"
  local expected_result="$3"  # "pass" or "fail"
  local expected_count="${4:-0}"

  TESTS_RUN=$((TESTS_RUN + 1))
  log_test "Running: $test_name"

  if [[ ! -f "$test_file" ]]; then
    echo "  FAIL: Test file not found: $test_file"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  local validation_result=""
  if validate_kilabz_result "$test_file" "$expected_count" 2>/dev/null; then
    validation_result="pass"
  else
    validation_result="fail"
  fi

  if [[ "$validation_result" == "$expected_result" ]]; then
    echo "  PASS: Expected $expected_result, got $validation_result"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "  FAIL: Expected $expected_result, got $validation_result"
    # Show the validation error for debugging
    validate_kilabz_result "$test_file" "$expected_count" 2>&1 | sed 's/^/    ERROR: /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# Test strict validation mode (default)
export KILABZ_STRICT_VALIDATION=true
log_test "Testing STRICT validation mode"

# Tests that should PASS
run_test "Well-formed PASS output" "$TEST_DIR/test-well-formed-pass.txt" "pass"
run_test "Well-formed FAIL output" "$TEST_DIR/test-well-formed-fail.txt" "pass"

# Tests that should FAIL
run_test "Missing verdict" "$TEST_DIR/test-missing-verdict.txt" "fail"
run_test "Missing evidence" "$TEST_DIR/test-missing-evidence.txt" "fail"
run_test "Invalid evidence format" "$TEST_DIR/test-invalid-evidence-format.txt" "fail"
run_test "Inconsistent verdict" "$TEST_DIR/test-inconsistent-verdict.txt" "fail"
run_test "Partial/incomplete output" "$TEST_DIR/test-partial-output.txt" "fail"

# Test expected count validation
run_test "Insufficient findings count" "$TEST_DIR/test-well-formed-pass.txt" "fail" 5

# Real-world fixtures from bridge/processed/* — production shape
# (raw agent stdout, the slice the watcher actually validates after
# harvest from /tmp/kilabz-last-message.txt). All MUST pass.
run_test "Real KilaBz #1 (sec review, FAIL verdict)"     "$TEST_DIR/test-real-kilabz-1.txt" "pass"
run_test "Real KilaBz #2 (correctness, FAIL verdict)"    "$TEST_DIR/test-real-kilabz-2.txt" "pass"
run_test "Real KilaBz #3 (correctness v3, FAIL verdict)" "$TEST_DIR/test-real-kilabz-3.txt" "pass"
run_test "Real KilaBz #4 (style, FAIL verdict)"          "$TEST_DIR/test-real-kilabz-4.txt" "pass"
run_test "Real KilaBz #5 (sec review, FAIL verdict)"     "$TEST_DIR/test-real-kilabz-5.txt" "pass"

# Test fallback mode
export KILABZ_STRICT_VALIDATION=false
log_test ""
log_test "Testing FALLBACK validation mode"

# In fallback mode, some strict failures should pass (but not all)
run_test "Fallback: Well-formed PASS" "$TEST_DIR/test-well-formed-pass.txt" "pass"
run_test "Fallback: Missing verdict still fails" "$TEST_DIR/test-missing-verdict.txt" "fail"
run_test "Fallback: Missing evidence still fails" "$TEST_DIR/test-missing-evidence.txt" "fail"
# Note: Invalid evidence format should pass in fallback mode (loose regex)

# Test feature flag switching
export KILABZ_STRICT_VALIDATION=true
run_test "Feature flag: Strict mode enabled" "$TEST_DIR/test-invalid-evidence-format.txt" "fail"

export KILABZ_STRICT_VALIDATION=false
run_test "Feature flag: Fallback mode enabled" "$TEST_DIR/test-well-formed-pass.txt" "pass"

# Real KilaBz fixtures pulled from bridge/processed/ — guards against the
# strict validator regressing on legitimate variation in real-world output
# (template/prompt text co-located with model output, multi-verdict files).
export KILABZ_STRICT_VALIDATION=true
log_test ""
log_test "Testing against REAL KilaBz outputs from bridge/processed/"
run_test "Real KilaBz #1 (security review, 12 findings, 3 verdicts)"  "$TEST_DIR/test-real-kilabz-1.txt" "pass"
run_test "Real KilaBz #2 (correctness review, 2 findings, 4 verdicts)" "$TEST_DIR/test-real-kilabz-2.txt" "pass"
run_test "Real KilaBz #3 (12 findings)"                                "$TEST_DIR/test-real-kilabz-3.txt" "pass"
run_test "Real KilaBz #4 (6 findings, 3 verdicts)"                     "$TEST_DIR/test-real-kilabz-4.txt" "pass"
run_test "Real KilaBz #5 (6 findings, 4 verdicts)"                     "$TEST_DIR/test-real-kilabz-5.txt" "pass"

# Summary
log_test ""
log_test "Test Results:"
log_test "  Total tests run: $TESTS_RUN"
log_test "  Passed: $TESTS_PASSED"
log_test "  Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
  log_test "All tests PASSED! ✅"
  exit 0
else
  log_test "Some tests FAILED! ❌"
  exit 1
fi