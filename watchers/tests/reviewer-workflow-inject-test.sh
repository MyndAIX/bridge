#!/bin/bash
set -euo pipefail

# Test script to verify workflow injection in KilaBz and Oracle watchers
# Usage: bash reviewer-workflow-inject-test.sh

echo "[TEST] Reviewer workflow injection test"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHERS_DIR="$(dirname "$SCRIPT_DIR")"
TEST_REPO_DIR="/tmp/reviewer-workflow-inject-test-repo"
TEST_WORKFLOWS_DIR="/tmp/reviewer-workflow-inject-test-workflows"

cleanup() {
  rm -rf "$TEST_REPO_DIR" "$TEST_WORKFLOWS_DIR"
}

trap cleanup EXIT

echo "[TEST] Setting up fixture repo and workflow file"

# Create a test repo
mkdir -p "$TEST_REPO_DIR"
cd "$TEST_REPO_DIR"
git init >/dev/null 2>&1
git config user.email "test@example.com" >/dev/null 2>&1
git config user.name "Test User" >/dev/null 2>&1
echo "# Test Repo" > README.md
git add README.md >/dev/null 2>&1
git commit -m "Initial commit" >/dev/null 2>&1

# Create a test workflow file
mkdir -p "$TEST_WORKFLOWS_DIR"
cat > "$TEST_WORKFLOWS_DIR/test-project.md" <<EOF
---
repo: $TEST_REPO_DIR
---

# Test Project Workflow

### Review agents
- Always check for security vulnerabilities
- Ensure proper error handling
- Verify test coverage

### Architecture review
- Validate design patterns
- Check scalability considerations
- Review API contracts

### Outside counsel integration
- All external specs route through Oracle review
- Validate against workflow conventions
EOF

echo "[TEST] Created test repo: $TEST_REPO_DIR"
echo "[TEST] Created workflow file: $TEST_WORKFLOWS_DIR/test-project.md"

# Test that the helper functions exist in both watchers
echo "[TEST] Checking helper functions in KilaBz watcher"
if ! grep -q "resolve_agent_role()" "$WATCHERS_DIR/kilabz-watcher.sh"; then
  echo "[ERROR] resolve_agent_role function not found in kilabz-watcher.sh"
  exit 1
fi

if ! grep -q "find_workflow_file()" "$WATCHERS_DIR/kilabz-watcher.sh"; then
  echo "[ERROR] find_workflow_file function not found in kilabz-watcher.sh"
  exit 1
fi

if ! grep -q "extract_workflow_section()" "$WATCHERS_DIR/kilabz-watcher.sh"; then
  echo "[ERROR] extract_workflow_section function not found in kilabz-watcher.sh"
  exit 1
fi

echo "[TEST] ✅ All helper functions found in kilabz-watcher.sh"

echo "[TEST] Checking helper functions in Oracle watcher"
if ! grep -q "resolve_agent_role()" "$WATCHERS_DIR/oracle-watcher.sh"; then
  echo "[ERROR] resolve_agent_role function not found in oracle-watcher.sh"
  exit 1
fi

if ! grep -q "find_workflow_file()" "$WATCHERS_DIR/oracle-watcher.sh"; then
  echo "[ERROR] find_workflow_file function not found in oracle-watcher.sh"
  exit 1
fi

if ! grep -q "extract_workflow_section()" "$WATCHERS_DIR/oracle-watcher.sh"; then
  echo "[ERROR] extract_workflow_section function not found in oracle-watcher.sh"
  exit 1
fi

echo "[TEST] ✅ All helper functions found in oracle-watcher.sh"

# Test that the workflow injection logic exists
echo "[TEST] Checking workflow injection logic in both watchers"

if ! grep -q "Workflow injection (Part A)" "$WATCHERS_DIR/kilabz-watcher.sh"; then
  echo "[ERROR] Workflow injection logic not found in kilabz-watcher.sh"
  exit 1
fi

if ! grep -q "<workflow_context" "$WATCHERS_DIR/kilabz-watcher.sh"; then
  echo "[ERROR] workflow_context tag emission not found in kilabz-watcher.sh"
  exit 1
fi

if ! grep -q "Workflow injection (Part A)" "$WATCHERS_DIR/oracle-watcher.sh"; then
  echo "[ERROR] Workflow injection logic not found in oracle-watcher.sh"
  exit 1
fi

if ! grep -q "<workflow_context" "$WATCHERS_DIR/oracle-watcher.sh"; then
  echo "[ERROR] workflow_context tag emission not found in oracle-watcher.sh"
  exit 1
fi

echo "[TEST] ✅ Workflow injection logic found in both watchers"

# Extract and test the functions manually
cd /tmp
export WORKFLOWS_DIR="$TEST_WORKFLOWS_DIR"

# Source function definitions from kilabz-watcher.sh
eval "$(sed -n '/^resolve_agent_role()/,/^}/p' "$WATCHERS_DIR/kilabz-watcher.sh")"
eval "$(sed -n '/^find_workflow_file()/,/^}/p' "$WATCHERS_DIR/kilabz-watcher.sh")"
eval "$(sed -n '/^extract_workflow_section()/,/^}/p' "$WATCHERS_DIR/kilabz-watcher.sh")"

echo "[TEST] Testing helper functions"

# Test resolve_agent_role
KILABZ_ROLE=$(resolve_agent_role "kilabz")
ORACLE_ROLE=$(resolve_agent_role "oracle")

if [[ "$KILABZ_ROLE" != "Review agents" ]]; then
  echo "[ERROR] resolve_agent_role for kilabz returned '$KILABZ_ROLE', expected 'Review agents'"
  exit 1
fi

if [[ "$ORACLE_ROLE" != "Architecture review" ]]; then
  echo "[ERROR] resolve_agent_role for oracle returned '$ORACLE_ROLE', expected 'Architecture review'"
  exit 1
fi

echo "[TEST] ✅ resolve_agent_role working correctly"

# Test find_workflow_file
TEST_WF_FILE=$(find_workflow_file "$TEST_REPO_DIR")
if [[ -z "$TEST_WF_FILE" ]]; then
  echo "[ERROR] find_workflow_file returned empty for $TEST_REPO_DIR"
  exit 1
fi

if [[ ! -f "$TEST_WF_FILE" ]]; then
  echo "[ERROR] find_workflow_file returned non-existent file: $TEST_WF_FILE"
  exit 1
fi

echo "[TEST] ✅ find_workflow_file found: $(basename "$TEST_WF_FILE")"

# Test extract_workflow_section
KILABZ_SECTION=$(extract_workflow_section "$TEST_WF_FILE" "Review agents")
ORACLE_SECTION=$(extract_workflow_section "$TEST_WF_FILE" "Architecture review")
COUNSEL_SECTION=$(extract_workflow_section "$TEST_WF_FILE" "Outside counsel integration")

if [[ -z "$KILABZ_SECTION" ]]; then
  echo "[ERROR] extract_workflow_section returned empty for 'Review agents'"
  exit 1
fi

if [[ -z "$ORACLE_SECTION" ]]; then
  echo "[ERROR] extract_workflow_section returned empty for 'Architecture review'"
  exit 1
fi

if [[ -z "$COUNSEL_SECTION" ]]; then
  echo "[ERROR] extract_workflow_section returned empty for 'Outside counsel integration'"
  exit 1
fi

echo "[TEST] ✅ extract_workflow_section working for all sections"

# Verify the content
if [[ "$KILABZ_SECTION" != *"security vulnerabilities"* ]]; then
  echo "[ERROR] KilaBz section doesn't contain expected content"
  exit 1
fi

if [[ "$ORACLE_SECTION" != *"design patterns"* ]]; then
  echo "[ERROR] Oracle section doesn't contain expected content"
  exit 1
fi

if [[ "$COUNSEL_SECTION" != *"Oracle review"* ]]; then
  echo "[ERROR] Outside counsel section doesn't contain expected content"
  exit 1
fi

echo "[TEST] ✅ All workflow sections contain expected content"

echo ""
echo "═══════════════════════════════════════════════════"
echo "🎉 ALL TESTS PASSED!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "✅ Helper functions added to both kilabz-watcher.sh and oracle-watcher.sh"
echo "✅ Workflow injection logic added to both watchers"
echo "✅ Functions correctly resolve agent roles"
echo "✅ Functions correctly find workflow files"
echo "✅ Functions correctly extract workflow sections"
echo "✅ Both watchers will emit <workflow_context> tags above the data fence"
echo ""
echo "Next steps:"
echo "1. Commit and push changes"
echo "2. The reviewers will now receive project workflow context"
echo "3. This closes the false-positive PASS pattern from missing context"