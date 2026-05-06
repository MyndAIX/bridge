#!/usr/bin/env bash
# dispatch.sh — Bulletproof task dispatcher for MyndAIX bridge
# Enforces schema so agents can't produce bad frontmatter.

set -euo pipefail

export HOME="${HOME:-/Users/$(whoami)}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.myndaix/bridge}"
[[ -f "$HOME/.myndaix/.secrets" ]] && source "$HOME/.myndaix/.secrets"
FROM="lobster"
TIER="auto"
DRY_RUN=0

print_help() {
  cat <<'EOF'
dispatch.sh — schema-enforced task dispatcher for MyndAIX bridge

Usage:
  dispatch.sh --to <agent> --subject <text> --objective <text> [options]

Required:
  --to <agent>          Target agent (lobster, mack, mini, antman, kilabz,
                        recon, harley, oracle, smoke, cli)
  --subject <text>      Short title (≤ 80 chars)
  --objective <text>    What success looks like

Optional (most tasks):
  --from <agent>        Sender (default: lobster). Use 'cli' for human-typed
                        dispatches from a terminal.
  --type <type>         task | review | research | qa  (auto-detected from --to)
  --priority <P0..P3>   Required for type:task and type:qa
  --tier <auto|manual>  Default: auto (watcher claims it autonomously)
  --scope-in <list>     Comma-separated files/paths in scope (required for tasks)
  --scope-out <list>    Comma-separated files/paths out of scope
  --done <criteria>     Comma-separated success criteria (required for tasks)
  --body <text>         Detailed instructions; goes after the frontmatter
  --repo <path>         Target repo path (default: ~/.openclaw/workspace)
  --branch <name>       Required for type:review
  --risk <low|med|high> Risk level
  --dispatch-to <list>  Pipe-separated chain dispatch
  --dry-run             Print the would-be task file to stdout, don't write
  --help, -h            Show this message

Examples:
  ./scripts/dispatch.sh --to mini --from cli \
    --subject "say hello" --objective "echo a friendly message" \
    --priority P3 --scope-in "/tmp" --done "Output is non-empty" \
    --body "echo hello from mini"

  ./scripts/dispatch.sh --to oracle --from cli --type review \
    --branch feature/auth --subject "review SPEC-AUTH-001" \
    --objective "approve or list blockers" \
    --body "$(cat factory/specs/SPEC-AUTH-001.md)"

  ./scripts/dispatch.sh --to recon --from cli \
    --subject "research competitor pricing" \
    --objective "list 5 competitors with pricing tiers" \
    --body "Focus on enterprise SaaS analytics tools"

Behavior:
  Writes a frontmatter+body markdown file atomically (mktemp + mv) to
  $BRIDGE_DIR/inbox/<agent>/<timestamp>-<from>-<type>-<slug>.md
  The matching watcher picks it up and processes it; the result lands
  in $BRIDGE_DIR/inbox/lobster/.
EOF
}

# --- Parse args ---
TO=""
TYPE=""
SUBJECT=""
OBJECTIVE=""
PRIORITY=""
SCOPE_IN=""
SCOPE_OUT=""
DONE_CRITERIA=""
BODY=""
REPO=""
BRANCH=""
RISK_LEVEL=""
DISPATCH_TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)       TO="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    --subject)  SUBJECT="$2"; shift 2 ;;
    --objective) OBJECTIVE="$2"; shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --scope-in) SCOPE_IN="$2"; shift 2 ;;
    --scope-out) SCOPE_OUT="$2"; shift 2 ;;
    --done)     DONE_CRITERIA="$2"; shift 2 ;;
    --body)     BODY="$2"; shift 2 ;;
    --tier)     TIER="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    --risk)     RISK_LEVEL="$2"; shift 2 ;;
    --dispatch-to) DISPATCH_TO="$2"; shift 2 ;;
    --type)     TYPE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  print_help; exit 0 ;;
    *) echo "Unknown arg: $1"; echo; print_help; exit 1 ;;
  esac
done

# --- Validate required base fields ---
if [[ -z "$TO" ]]; then echo "ERROR: --to required"; exit 1; fi
if [[ -z "$SUBJECT" ]]; then echo "ERROR: --subject required"; exit 1; fi
if [[ -z "$OBJECTIVE" ]]; then echo "ERROR: --objective required"; exit 1; fi

# --- Validate agent name ---
VALID_AGENTS="lobster mack mini antman kilabz recon harley oracle smoke cli"
if ! echo "$VALID_AGENTS" | grep -qw "$TO"; then
  echo "ERROR: Invalid agent '$TO'. Must be one of: $VALID_AGENTS"
  exit 1
fi
if ! echo "$VALID_AGENTS" | grep -qw "$FROM"; then
  echo "ERROR: Invalid from '$FROM'. Must be one of: $VALID_AGENTS"
  exit 1
fi

# --- Auto-detect type from target agent ---
if [[ -z "$TYPE" ]]; then
  case "$TO" in
    mini|antman|harley|mack) TYPE="task" ;;
    kilabz)                  TYPE="review" ;;
    recon)                   TYPE="research" ;;
    smoke)                   TYPE="qa" ;;
    *) echo "ERROR: Can't auto-detect type for '$TO'. Use --type"; exit 1 ;;
  esac
fi

# --- Validate type matches agent ---
case "$TO" in
  mini|antman|harley|mack)
    if [[ "$TYPE" != "task" ]]; then
      echo "ERROR: $TO only accepts type:task, got type:$TYPE"
      exit 1
    fi ;;
  kilabz)
    if [[ "$TYPE" != "task" && "$TYPE" != "review" ]]; then
      echo "ERROR: kilabz only accepts type:task or type:review, got type:$TYPE"
      exit 1
    fi ;;
  recon)
    if [[ "$TYPE" != "research" ]]; then
      echo "ERROR: recon only accepts type:research, got type:$TYPE"
      exit 1
    fi ;;
  smoke)
    if [[ "$TYPE" != "qa" ]]; then
      echo "ERROR: smoke only accepts type:qa, got type:$TYPE"
      exit 1
    fi ;;
esac

# --- Validate priority ---
if [[ -n "$PRIORITY" ]]; then
  if ! echo "P0 P1 P2 P3" | grep -qw "$PRIORITY"; then
    echo "ERROR: Invalid priority '$PRIORITY'. Must be P0, P1, P2, or P3"
    exit 1
  fi
fi

# --- Validate tier ---
if ! echo "auto manual" | grep -qw "$TIER"; then
  echo "ERROR: Invalid tier '$TIER'. Must be auto or manual"
  exit 1
fi

# --- Task-specific validation ---
if [[ "$TYPE" == "task" ]]; then
  if [[ -z "$PRIORITY" ]]; then echo "ERROR: --priority required for tasks"; exit 1; fi
  if [[ -z "$SCOPE_IN" ]]; then echo "ERROR: --scope-in required for tasks"; exit 1; fi
  if [[ -z "$DONE_CRITERIA" ]]; then echo "ERROR: --done required for tasks"; exit 1; fi
fi

if [[ "$TYPE" == "qa" ]]; then
  if [[ -z "$PRIORITY" ]]; then echo "ERROR: --priority required for qa tasks"; exit 1; fi
  if [[ -z "$SCOPE_IN" ]]; then echo "ERROR: --scope-in required for qa tasks"; exit 1; fi
  if [[ -z "$DONE_CRITERIA" ]]; then echo "ERROR: --done required for qa tasks"; exit 1; fi
fi

if [[ "$TYPE" == "review" ]]; then
  if [[ -z "$BRANCH" ]]; then echo "ERROR: --branch required for reviews"; exit 1; fi
fi

# --- Generate filename ---
TIMESTAMP=$(date -u +"%Y%m%d%H%M%S")
SLUG=$(echo "$SUBJECT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
FILENAME="${TIMESTAMP}-${FROM}-${TYPE}-${SLUG}.md"
INBOX_DIR="${BRIDGE_DIR}/inbox/${TO}"

# --- Ensure inbox exists ---
mkdir -p "$INBOX_DIR"

# --- Build frontmatter ---
FM="---\n"
FM+="from: ${FROM}\n"
FM+="to: ${TO}\n"
FM+="type: ${TYPE}\n"
FM+="subject: \"${SUBJECT}\"\n"
FM+="objective: \"${OBJECTIVE}\"\n"

if [[ -n "$PRIORITY" ]]; then
  FM+="priority: ${PRIORITY}\n"
fi

FM+="tier: ${TIER}\n"
FM+="created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")\n"

# Always include repo — watcher uses scope as repo path if repo is missing
if [[ -z "$REPO" ]]; then
  REPO="$HOME/.openclaw/workspace"
fi
FM+="repo: ${REPO}\n"
if [[ -n "$BRANCH" ]]; then
  FM+="branch: ${BRANCH}\n"
fi
if [[ -n "$RISK_LEVEL" ]]; then
  FM+="risk_level: ${RISK_LEVEL}\n"
fi
if [[ -n "$DISPATCH_TO" ]]; then
  FM+="dispatch_to: ${DISPATCH_TO}\n"
fi

# --- Scope block (task/review) ---
if [[ -n "$SCOPE_IN" || -n "$SCOPE_OUT" ]]; then
  FM+="scope:\n"
  if [[ -n "$SCOPE_IN" ]]; then
    FM+="  in:\n"
    IFS=',' read -ra ITEMS <<< "$SCOPE_IN"
    for item in "${ITEMS[@]}"; do
      item=$(echo "$item" | xargs)  # trim whitespace
      FM+="    - \"${item}\"\n"
    done
  fi
  if [[ -n "$SCOPE_OUT" ]]; then
    FM+="  out:\n"
    IFS=',' read -ra ITEMS <<< "$SCOPE_OUT"
    for item in "${ITEMS[@]}"; do
      item=$(echo "$item" | xargs)
      FM+="    - \"${item}\"\n"
    done
  fi
fi

# --- Done criteria block (task) ---
if [[ -n "$DONE_CRITERIA" ]]; then
  FM+="done_criteria:\n"
  IFS=',' read -ra ITEMS <<< "$DONE_CRITERIA"
  for item in "${ITEMS[@]}"; do
    item=$(echo "$item" | xargs)
    FM+="  - \"${item}\"\n"
  done
fi

FM+="---\n"

# --- Compose final content (frontmatter + body) ---
FILEPATH="${INBOX_DIR}/${FILENAME}"
CONTENT=$(printf '%b' "$FM")
if [[ -n "$BODY" ]]; then
  CONTENT+=$'\n'"$BODY"$'\n'
fi

# --- Dry-run: print to stdout and exit; don't write to inbox ---
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "# DRY RUN — would write: $FILEPATH"
  echo "# (run without --dry-run to dispatch)"
  echo
  printf '%s\n' "$CONTENT"
  exit 0
fi

# --- Atomic write: mktemp + mv (the watcher must never see a partial file) ---
TMP=$(mktemp "${INBOX_DIR}/.${FILENAME}.tmp.XXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$CONTENT" > "$TMP"
mv "$TMP" "$FILEPATH"
trap - EXIT

echo "✓ Dispatched: ${FILEPATH}"
echo "  To: ${TO} | Type: ${TYPE} | Priority: ${PRIORITY:-n/a}"
