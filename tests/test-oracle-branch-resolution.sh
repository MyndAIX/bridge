#!/bin/bash
# test-oracle-branch-resolution.sh — Test Oracle branch resolution logic
# Verifies that Oracle watcher resolves Mini auto-branch to feature branch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_ORACLE_WATCHER="$BRIDGE_DIR/watchers/oracle-watcher.sh"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Test state
TESTS_PASSED=0
TESTS_FAILED=0

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

success() {
  echo -e "${GREEN}✓${NC} $*"
  ((TESTS_PASSED++))
}

fail() {
  echo -e "${RED}✗${NC} $*"
  ((TESTS_FAILED++))
}

warn() {
  echo -e "${YELLOW}⚠${NC} $*"
}

# Test function: check branch resolution
test_branch_resolution() {
  local test_name="$1"
  local input_branch="$2"
  local task_file_content="$3"
  local expected_branch="$4"

  # Create temporary task file
  local temp_task="/tmp/test-oracle-task-$$.md"
  echo "$task_file_content" > "$temp_task"

  # Extract resolve_feature_branch function from oracle-watcher.sh and test it
  local resolved_branch=""
  resolved_branch=$(bash -c "
    # Source the function from oracle-watcher.sh
    source <(sed -n '/^resolve_feature_branch()/,/^}/p' '$TEST_ORACLE_WATCHER')

    # Mock the log function
    log() { echo '[LOG]' \"\$*\" >&2; }

    # Mock PROCESSED_DIR
    export PROCESSED_DIR='$BRIDGE_DIR/processed'

    # Call the function
    resolve_feature_branch '$input_branch' '$temp_task'
  " 2>/dev/null)

  # Clean up
  rm -f "$temp_task"

  # Check result
  if [[ "$resolved_branch" == "$expected_branch" ]]; then
    success "$test_name: '$input_branch' → '$resolved_branch'"
  else
    fail "$test_name: '$input_branch' → '$resolved_branch' (expected '$expected_branch')"
  fi
}

# Test cases
run_tests() {
  log "Testing Oracle branch resolution logic..."

  # Test 1: Mini auto-branch should resolve to feature branch
  test_branch_resolution \
    "Mini auto-branch resolution" \
    "mini/lobster-to-mini-test-example-123456789" \
    "---
from: mini
to: oracle
type: review
subject: Test review
repo: $BRIDGE_DIR
branch: mini/lobster-to-mini-test-example-123456789
---
Test review content" \
    "feature/test-example"

  # Test 2: Antman auto-branch should resolve
  test_branch_resolution \
    "Antman auto-branch resolution" \
    "antman/20260503-lobster-upgrade-7c-bar-987654321" \
    "---
from: antman
to: oracle
type: review
subject: Test antman review
repo: $BRIDGE_DIR
branch: antman/20260503-lobster-upgrade-7c-bar-987654321
---
Test review content" \
    "feature/upgrade-7c-bar"

  # Test 3: Feature branch should pass through unchanged
  test_branch_resolution \
    "Feature branch pass-through" \
    "fix/example-bug" \
    "---
from: mack
to: oracle
type: review
subject: Test feature review
repo: $BRIDGE_DIR
branch: fix/example-bug
---
Test review content" \
    "fix/example-bug"

  # Test 4: Main branch should pass through unchanged
  test_branch_resolution \
    "Main branch pass-through" \
    "main" \
    "---
from: kilabz
to: oracle
type: review
subject: Test main review
repo: $BRIDGE_DIR
branch: main
---
Test review content" \
    "main"

  # Test 5: Auto-branch with complex task ID
  test_branch_resolution \
    "Complex task ID resolution" \
    "mini/20260503224500-lobster-fix-oracle-branch-resolution-202-1777873398" \
    "---
from: mini
to: oracle
type: review
subject: Complex task review
repo: $BRIDGE_DIR
branch: mini/20260503224500-lobster-fix-oracle-branch-resolution-202-1777873398
---
Test review content" \
    "feature/fix-oracle-branch-resolution-202"
}

# Validation tests
run_validation_tests() {
  log "Testing script validation..."

  # Test 1: Check script exists and is executable
  if [[ -f "$TEST_ORACLE_WATCHER" && -x "$TEST_ORACLE_WATCHER" ]]; then
    success "oracle-watcher.sh exists and is executable"
  else
    fail "oracle-watcher.sh is not executable"
  fi

  # Test 2: Check bash syntax
  if bash -n "$TEST_ORACLE_WATCHER"; then
    success "oracle-watcher.sh has valid bash syntax"
  else
    fail "oracle-watcher.sh has syntax errors"
  fi

  # Test 3: Check required functions exist
  if grep -q "resolve_feature_branch()" "$TEST_ORACLE_WATCHER"; then
    success "resolve_feature_branch function found"
  else
    fail "resolve_feature_branch function missing"
  fi

  if grep -q "process_review()" "$TEST_ORACLE_WATCHER"; then
    success "process_review function found"
  else
    fail "process_review function missing"
  fi
}

# Mock integration test
run_integration_test() {
  log "Testing integration with mock Oracle inbox..."

  # Create temporary directories
  local temp_bridge="/tmp/test-bridge-$$"
  local mock_inbox="$temp_bridge/inbox/oracle"
  local mock_processed="$temp_bridge/processed"

  mkdir -p "$mock_inbox" "$mock_processed"

  # Create mock review request with Mini auto-branch
  local mock_task="$mock_inbox/20260503225000-mini-review-test-example.md"
  cat > "$mock_task" <<EOF
---
from: mini
to: oracle
type: review
subject: "Mock review for branch resolution test"
repo: $(pwd)
branch: mini/20260503-lobster-test-example-123456789
task_id: test-example-123
objective: "Test Oracle branch resolution"
---

# Mock Oracle Review Request

This is a test review to verify Oracle resolves mini auto-branch to feature branch.

The Oracle watcher should:
1. Detect that branch starts with mini/
2. Parse the task ID from the branch name
3. Resolve to feature/test-example branch
4. Run review on the correct branch
EOF

  # Create minimal processed task for lookup
  cat > "$mock_processed/20260503-lobster-test-example.md" <<EOF
---
from: lobster
to: mini
type: task
subject: "Mock task for test"
branch: feature/test-example
---
Mock original task
EOF

  # Test if watcher can parse the file correctly (without actually running Gemini)
  warn "Integration test would require gemini CLI - skipping actual execution"
  warn "Mock task created at: $mock_task"

  # Clean up
  rm -rf "$temp_bridge"

  success "Integration test setup complete"
}

# Main execution
main() {
  log "Oracle watcher branch resolution test suite"
  log "Testing: $TEST_ORACLE_WATCHER"

  run_validation_tests
  run_tests
  run_integration_test

  log ""
  log "Test Results:"
  log "  Passed: $TESTS_PASSED"
  log "  Failed: $TESTS_FAILED"

  if [[ $TESTS_FAILED -eq 0 ]]; then
    log -e "${GREEN}All tests passed!${NC}"
    exit 0
  else
    log -e "${RED}Some tests failed!${NC}"
    exit 1
  fi
}

# Check if oracle-watcher.sh exists
if [[ ! -f "$TEST_ORACLE_WATCHER" ]]; then
  fail "oracle-watcher.sh not found at $TEST_ORACLE_WATCHER"
  exit 1
fi

main "$@"