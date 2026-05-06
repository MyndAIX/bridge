#!/bin/bash
# test-workflow-injection.sh — Verify Upgrade 7 Part A workflow context injection
# Tests: workflow file lookup by repo, agent role resolution, section extraction,
#        and full prompt injection preview for a mock fieldvision task.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOWS_DIR="$HOME/.myndaix/factory/workflows"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "=== Upgrade 7 Part A — Workflow Injection Tests ==="
echo

# ── Test 1: Workflow files exist ──
echo "1. Workflow files exist"
[[ -f "$WORKFLOWS_DIR/fieldvision.md" ]] && ok "fieldvision.md exists" || fail "fieldvision.md missing"
[[ -f "$WORKFLOWS_DIR/myndaix.md" ]]     && ok "myndaix.md exists"     || fail "myndaix.md missing"
echo

# ── Test 2: Workflow frontmatter is valid YAML ──
echo "2. Frontmatter parses as valid YAML"
for f in "$WORKFLOWS_DIR"/*.md; do
  name=$(basename "$f")
  if ruby -ryaml -rdate -e '
    c = File.read(ARGV[0])
    m = c.match(/\A---\s*\n(.*?)\n---/m)
    abort("no frontmatter") unless m
    YAML.safe_load(m[1], permitted_classes: [Date, Time])
  ' "$f" 2>/dev/null; then
    ok "$name frontmatter valid"
  else
    fail "$name frontmatter invalid"
  fi
done
echo

# ── Test 3: Agent role resolution ──
echo "3. Agent role resolution"
resolve_agent_role() {
  case "$1" in
    mini|mack|antman) echo "Build agents" ;;
    kilabz)           echo "Review agents" ;;
    oracle)           echo "Architecture review" ;;
    recon)            echo "Research" ;;
    harley)           echo "Creative" ;;
    *)                echo "" ;;
  esac
}
[[ "$(resolve_agent_role mini)"   == "Build agents" ]]          && ok "mini → Build agents"          || fail "mini role"
[[ "$(resolve_agent_role kilabz)" == "Review agents" ]]         && ok "kilabz → Review agents"       || fail "kilabz role"
[[ "$(resolve_agent_role oracle)" == "Architecture review" ]]   && ok "oracle → Architecture review" || fail "oracle role"
[[ "$(resolve_agent_role recon)"  == "Research" ]]               && ok "recon → Research"             || fail "recon role"
[[ "$(resolve_agent_role harley)" == "Creative" ]]               && ok "harley → Creative"            || fail "harley role"
[[ -z "$(resolve_agent_role smoke)" ]]                           && ok "smoke → (empty)"              || fail "smoke role"
echo

# ── Test 4: Repo-to-workflow matching ──
echo "4. Repo-to-workflow file matching"
find_workflow_file() {
  local task_repo="$1"
  [[ -z "$task_repo" || ! -d "$WORKFLOWS_DIR" ]] && return 0
  local expanded_repo="${task_repo/#\~/$HOME}"
  local best_file="" best_len=0
  for wf in "$WORKFLOWS_DIR"/*.md; do
    [[ ! -f "$wf" ]] && continue
    local wf_repo
    wf_repo=$(awk '/^---$/{c++; next} c==1 && /^repo:/{sub(/^repo:[[:space:]]*/, ""); print; exit}' "$wf")
    [[ -z "$wf_repo" ]] && continue
    local expanded_wf="${wf_repo/#\~/$HOME}"
    local match_len=0
    if [[ "$expanded_repo" == "$expanded_wf" ]]; then
      match_len=${#expanded_wf}
    else
      local proj_name
      proj_name=$(basename "$expanded_wf")
      if [[ "$expanded_repo" == *"/$proj_name"* || "$expanded_repo" == *"$proj_name"* ]]; then
        match_len=${#expanded_wf}
      fi
    fi
    if (( match_len > best_len )) || { (( match_len == best_len )) && (( match_len > 0 )) && [[ "$wf" < "$best_file" ]]; }; then
      best_file="$wf"
      best_len=$match_len
    fi
  done
  [[ -n "$best_file" ]] && echo "$best_file"
  return 0
}

wf=$(find_workflow_file "$HOME/code/active/fieldvision")
[[ "$wf" == *"fieldvision.md" ]] && ok "exact fieldvision path → fieldvision.md" || fail "fieldvision path match (got: $wf)"

wf=$(find_workflow_file "~/code/active/fieldvision")
[[ "$wf" == *"fieldvision.md" ]] && ok "tilde fieldvision path → fieldvision.md" || fail "tilde fieldvision match (got: $wf)"

wf=$(find_workflow_file "$HOME/.myndaix/bridge")
[[ "$wf" == *"myndaix.md" ]] && ok "bridge path → myndaix.md" || fail "bridge path match (got: $wf)"

wf=$(find_workflow_file "/some/random/path")
[[ -z "$wf" ]] && ok "unknown repo → no match" || fail "unknown repo matched (got: $wf)"
echo

# ── Test 5: Section extraction ──
echo "5. Section extraction from workflow"
extract_workflow_section() {
  local wf_file="$1" role="$2"
  [[ -z "$wf_file" || -z "$role" ]] && return 0
  awk -v role="$role" '
    /^### /{
      prefix = "### " role
      if (substr($0, 1, length(prefix)) == prefix) {
        rest = substr($0, length(prefix) + 1)
        if (rest == "" || substr(rest, 1, 2) == " (") { found=1; next }
      }
      if (found) { exit }
    }
    found { print }
  ' "$wf_file"
}

sec=$(extract_workflow_section "$WORKFLOWS_DIR/fieldvision.md" "Build agents")
echo "$sec" | grep -q "SwiftData" && ok "Build agents section has SwiftData" || fail "Build agents section content"
echo "$sec" | grep -q "MV pattern" && ok "Build agents section has MV pattern" || fail "MV pattern missing"

sec=$(extract_workflow_section "$WORKFLOWS_DIR/fieldvision.md" "Review agents")
echo "$sec" | grep -q "force-unwraps" && ok "Review agents section has force-unwraps check" || fail "Review agents content"

sec=$(extract_workflow_section "$WORKFLOWS_DIR/fieldvision.md" "Research")
echo "$sec" | grep -q "Procore" && ok "Research section has competitors" || fail "Research section content"

sec=$(extract_workflow_section "$WORKFLOWS_DIR/myndaix.md" "Build agents")
echo "$sec" | grep -q "bash -n" && ok "MyndAIX build section has bash -n" || fail "MyndAIX build section"
echo

# ── Test 6: Full injection preview (mock fieldvision task → mini) ──
echo "6. Full injection preview: mock fieldvision task dispatched to mini"
echo "---"

_wf_file=$(find_workflow_file "$HOME/code/active/fieldvision")
_wf_role=$(resolve_agent_role "mini")
_wf_section=$(extract_workflow_section "$_wf_file" "$_wf_role")
_wf_counsel=$(extract_workflow_section "$_wf_file" "Outside counsel integration")
_wf_project=$(basename "${_wf_file%.md}")

echo "  Workflow file:  $_wf_file"
echo "  Project:        $_wf_project"
echo "  Target agent:   mini"
echo "  Resolved role:  $_wf_role"
echo "---"
echo
echo "=== INJECTED WORKFLOW BLOCK (appended to task body) ==="
echo

_wf_block=""
if [[ -n "$_wf_section" || -n "$_wf_counsel" ]]; then
  _wf_block=$'\n## Workflow Context ('"$_wf_project"')\n'
  if [[ -n "$_wf_section" ]]; then
    _wf_block+=$'\n### '"$_wf_role"$'\n'"$_wf_section"
  fi
  if [[ -n "$_wf_counsel" ]]; then
    _wf_block+=$'\n### Outside counsel integration\n'"$_wf_counsel"
  fi
  echo "$_wf_block"
  ok "Workflow block generated for fieldvision/mini"
else
  fail "No workflow block generated"
fi
echo

# ── Test 7: agent-dispatch.sh passes bash -n ──
echo "7. Syntax check"
if bash -n "$SCRIPT_DIR/scripts/agent-dispatch.sh" 2>/dev/null; then
  ok "agent-dispatch.sh passes bash -n"
else
  fail "agent-dispatch.sh syntax error"
fi
echo

# ── Test 8: Longest-match repo selection ──
echo "8. Longest-match repo selection"
_LM_DIR=$(mktemp -d)
trap 'rm -rf "$_LM_DIR"' EXIT
cat > "$_LM_DIR/short-project.md" << 'WFEOF'
---
repo: /tmp/test-proj
project: short
---
### Build agents
short content
WFEOF
cat > "$_LM_DIR/long-project.md" << 'WFEOF'
---
repo: /tmp/test-proj/nested
project: long
---
### Build agents
long content
WFEOF
_ORIG_WD="$WORKFLOWS_DIR"
WORKFLOWS_DIR="$_LM_DIR"
wf=$(find_workflow_file "/tmp/test-proj/nested")
[[ "$wf" == *"long-project.md" ]] && ok "longest match wins (/tmp/test-proj/nested → long-project.md)" || fail "longest match (got: $wf)"
wf=$(find_workflow_file "/tmp/test-proj")
[[ "$wf" == *"short-project.md" ]] && ok "exact short match (/tmp/test-proj → short-project.md)" || fail "exact short match (got: $wf)"
WORKFLOWS_DIR="$_ORIG_WD"
echo

# ── Test 9: Anchored heading extraction ──
echo "9. Anchored heading extraction (no substring collisions)"
_AH_FILE=$(mktemp)
cat > "$_AH_FILE" << 'WFEOF'
---
repo: /tmp/anchor-test
---
### Build (CI)
- generic build notes

### Build agents (Mini, Antman)
- specific build-agent notes
WFEOF
sec=$(extract_workflow_section "$_AH_FILE" "Build agents")
echo "$sec" | grep -q "specific build-agent" && ok "\"Build agents\" matches exact heading" || fail "Build agents heading match"
echo "$sec" | grep -q "generic build notes" && fail "\"Build agents\" leaked \"Build\" content" || ok "\"Build agents\" does not leak \"Build\" content"
sec=$(extract_workflow_section "$_AH_FILE" "Build")
echo "$sec" | grep -q "generic build notes" && ok "\"Build\" matches exact heading" || fail "Build heading match"
echo "$sec" | grep -q "specific build-agent" && fail "\"Build\" leaked \"Build agents\" content" || ok "\"Build\" does not leak \"Build agents\" content"
rm -f "$_AH_FILE"
echo

# ── Summary ──
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$FAIL"
