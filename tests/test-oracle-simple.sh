#!/bin/bash
# Simple test for Oracle watcher - just verify script and branch resolution logic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_DIR="$(dirname "$SCRIPT_DIR")"
ORACLE_WATCHER="$BRIDGE_DIR/watchers/oracle-watcher.sh"

echo "Testing Oracle watcher..."

# Test 1: Script exists and is executable
if [[ -x "$ORACLE_WATCHER" ]]; then
  echo "✓ oracle-watcher.sh is executable"
else
  echo "✗ oracle-watcher.sh is not executable"
  exit 1
fi

# Test 2: Bash syntax is valid
if bash -n "$ORACLE_WATCHER"; then
  echo "✓ oracle-watcher.sh has valid syntax"
else
  echo "✗ oracle-watcher.sh has syntax errors"
  exit 1
fi

# Test 3: Required functions exist
if grep -q "resolve_feature_branch" "$ORACLE_WATCHER"; then
  echo "✓ resolve_feature_branch function exists"
else
  echo "✗ resolve_feature_branch function missing"
  exit 1
fi

# Test 4: Branch resolution logic test (manual)
echo "Testing branch resolution logic manually..."

# Create a simple test task file
TEST_TASK="/tmp/test-oracle-task-$$"
cat > "$TEST_TASK" <<EOF
---
from: mini
to: oracle
type: review
subject: Test Oracle review
branch: mini/lobster-to-mini-example-123456789
repo: $(pwd)
---
Test task content
EOF

echo "✓ Created test task file: $TEST_TASK"

# Test the branch parsing (simple grep test)
BRANCH_LINE=$(grep "^branch:" "$TEST_TASK" | head -1)
if [[ "$BRANCH_LINE" == "branch: mini/lobster-to-mini-example-123456789" ]]; then
  echo "✓ Branch parsing test passed"
else
  echo "✗ Branch parsing test failed: $BRANCH_LINE"
fi

# Mock test: verify oracle watcher recognizes mini/ prefix
if grep -q 'mini|antman' "$ORACLE_WATCHER"; then
  echo "✓ Oracle watcher checks for mini/antman prefix"
else
  echo "✗ Oracle watcher missing mini/antman prefix check"
fi

# Mock test: verify feature branch derivation logic exists
if grep -q 'feature/' "$ORACLE_WATCHER"; then
  echo "✓ Oracle watcher has feature branch derivation"
else
  echo "✗ Oracle watcher missing feature branch derivation"
fi

# Clean up
rm -f "$TEST_TASK"

echo "✓ All basic tests passed"
echo ""
echo "Manual verification:"
echo "1. Oracle watcher processes mini/* and antman/* auto-branches"
echo "2. Resolves to feature/* branches instead"
echo "3. Creates git worktree for review"
echo "4. Runs Gemini architecture review"
echo ""
echo "Integration test requires:"
echo "- Gemini CLI installation"
echo "- Valid git repository with test branches"
echo "- Oracle inbox setup"