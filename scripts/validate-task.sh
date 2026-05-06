#!/usr/bin/env bash
# validate-task.sh — MyndAIX Task Contract Validator
# Validates YAML frontmatter in bridge task files against TASK_SCHEMA.md
# Usage: validate-task.sh <path-to-task.md>
# Exit 0 = PASS, Exit 1 = FAIL

set -uo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- Args ---
if [[ $# -lt 1 ]]; then
    echo -e "${RED}FAIL${NC}: No file specified"
    echo "Usage: validate-task.sh <path-to-task.md>"
    exit 1
fi

TASK_FILE="$1"
AGENT_TYPE="${2:-}"

if [[ ! -f "$TASK_FILE" ]]; then
    echo -e "${RED}FAIL${NC}: File not found: $TASK_FILE"
    exit 1
fi

# --- Extract YAML frontmatter ---
# Grab everything between first --- and second ---
FRONTMATTER=$(awk '/^---$/{if(++c==1){next}if(c==2){exit}}c==1{print}' "$TASK_FILE")

if [[ -z "$FRONTMATTER" ]]; then
    echo -e "${RED}FAIL${NC}: No YAML frontmatter found in $TASK_FILE"
    exit 1
fi

# --- Helper: extract value for a key from frontmatter ---
get_field() {
    local key="$1"
    echo "$FRONTMATTER" | grep -E "^${key}:" | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | sed "s/^[[:space:]]*//" | sed "s/[[:space:]]*$//"
}

# --- Helper: check if field exists (non-empty) ---
has_field() {
    local key="$1"
    local val
    val=$(get_field "$key")
    [[ -n "$val" ]]
}

# --- Helper: check if a multiline/list field exists ---
has_block() {
    local key="$1"
    echo "$FRONTMATTER" | grep -qE "^${key}:" 2>/dev/null
}

# --- Collect missing fields ---
MISSING=()
WARNINGS=()

# --- Base required fields (all types) ---
for field in from type subject; do
    if ! has_field "$field"; then
        MISSING+=("$field")
    fi
done

# If we can't even get the type, fail now
MSG_TYPE=$(get_field "type")

if [[ -z "$MSG_TYPE" ]]; then
    echo -e "${RED}FAIL${NC}: $(basename "$TASK_FILE")"
    echo "  Missing fields: ${MISSING[*]}"
    exit 1
fi

# --- Agent-type registry check ---
if [[ -n "$AGENT_TYPE" ]]; then
    case "$AGENT_TYPE" in
        mini)    ALLOWED_TYPES="task" ;;
        antman)  ALLOWED_TYPES="task" ;;
        kilabz)  ALLOWED_TYPES="task review" ;;
        recon)   ALLOWED_TYPES="research" ;;
        harley)  ALLOWED_TYPES="task" ;;
        smoke)   ALLOWED_TYPES="qa task" ;;
        *)       ALLOWED_TYPES="" ;;
    esac
    if [[ -n "$ALLOWED_TYPES" ]] && ! echo "$ALLOWED_TYPES" | grep -qw "$MSG_TYPE"; then
        echo -e "${RED}FAIL${NC}: $(basename "$TASK_FILE")"
        echo "  Agent  does not accept type  (allowed: $ALLOWED_TYPES)"
        exit 1
    fi
fi

# --- Type-specific required fields ---
case "$MSG_TYPE" in
    task)
        for field in objective priority tier; do
            if ! has_field "$field"; then
                MISSING+=("$field")
            fi
        done
        for block in scope done_criteria; do
            if ! has_block "$block"; then
                MISSING+=("$block")
            fi
        done
        # Validate tier value
        if has_field "tier"; then
            TIER_VAL=$(get_field "tier")
            if [[ "$TIER_VAL" != "auto" && "$TIER_VAL" != "manual" ]]; then
                WARNINGS+=("tier '$TIER_VAL' should be auto|manual")
            fi
        fi
        # task_id links Notion board → bridge → Discord
        if ! has_field "task_id"; then
            WARNINGS+=("task_id missing — add MX-XX from Notion board for cross-system traceability")
        fi
        ;;
    review)
        for field in objective branch tier; do
            if ! has_field "$field"; then
                MISSING+=("$field")
            fi
        done
        if ! has_block "scope"; then
            MISSING+=("scope")
        fi
        # Validate tier value
        if has_field "tier"; then
            TIER_VAL=$(get_field "tier")
            if [[ "$TIER_VAL" != "auto" && "$TIER_VAL" != "manual" ]]; then
                WARNINGS+=("tier '$TIER_VAL' should be auto|manual")
            fi
        fi
        # task_id links Notion board → bridge → Discord
        if ! has_field "task_id"; then
            WARNINGS+=("task_id missing — add MX-XX from Notion board for cross-system traceability")
        fi
        ;;
    result)
        for field in status summary; do
            if ! has_field "$field"; then
                MISSING+=("$field")
            fi
        done
        # Warn if optional-but-recommended fields are missing
        for field in changed_files validation risks next_actions; do
            if ! has_block "$field" && ! has_field "$field"; then
                WARNINGS+=("$field")
            fi
        done
        # task_id for Notion sync traceability
        if ! has_field "task_id"; then
            WARNINGS+=("task_id missing — results without task_id won't sync to Notion board")
        fi
        ;;
    response|message)
        # Only base fields required — already checked above
        ;;
    alert)
        # Base fields required. Warn if no priority.
        if ! has_field "priority"; then
            WARNINGS+=("priority (recommended for alerts)")
        fi
        ;;
    research)
        for field in objective priority tier; do
            if ! has_field "$field"; then
                MISSING+=("$field")
            fi
        done
        if ! has_block "scope"; then
            WARNINGS+=("scope (recommended for research tasks)")
        fi
        if ! has_field "task_id"; then
            WARNINGS+=("task_id missing — add MX-XX from Notion board for cross-system traceability")
        fi
        ;;
    qa)
        for field in objective priority tier; do
            if ! has_field "$field"; then
                MISSING+=("$field")
            fi
        done
        for block in scope done_criteria; do
            if ! has_block "$block"; then
                MISSING+=("$block")
            fi
        done
        if has_field "tier"; then
            TIER_VAL=$(get_field "tier")
            if [[ "$TIER_VAL" != "auto" && "$TIER_VAL" != "manual" ]]; then
                WARNINGS+=("tier '$TIER_VAL' should be auto|manual")
            fi
        fi
        if ! has_field "task_id"; then
            WARNINGS+=("task_id missing — add MX-XX from Notion board for cross-system traceability")
        fi
        ;;
    *)
        echo -e "${YELLOW}WARN${NC}: Unknown type '$MSG_TYPE' — only base fields validated"
        ;;
esac

# --- Validate dispatch_to (optional, agent-to-agent routing) ---
if has_field "dispatch_to"; then
    DISPATCH_TO=$(get_field "dispatch_to")
    DISPATCHABLE="antman kilabz mini mack recon harley smoke"
    if ! echo "$DISPATCHABLE" | grep -qw "$DISPATCH_TO"; then
        WARNINGS+=("dispatch_to '$DISPATCH_TO' is not a dispatchable agent")
    fi
fi

# --- Validate chain (optional, origin tracking for agent-to-agent dispatch) ---
# chain is a YAML list — just check it exists, don't deep-validate
if has_block "chain"; then
    : # valid — no extra validation needed
fi

# --- Validate from/to values ---
VALID_AGENTS="lobster mack jefe mini antman kilabz recon harley smoke notion-poller auth-watchdog cli"
FROM_VAL=$(get_field "from")
TO_VAL=$(get_field "to")

if [[ -n "$FROM_VAL" ]] && ! echo "$VALID_AGENTS" | grep -qw "$FROM_VAL"; then
    WARNINGS+=("from '$FROM_VAL' is not a known agent")
fi

if [[ -n "$TO_VAL" ]] && ! echo "$VALID_AGENTS" | grep -qw "$TO_VAL"; then
    WARNINGS+=("to '$TO_VAL' is not a known agent")
fi

# --- Validate priority values ---
if has_field "priority"; then
    PRIORITY_VAL=$(get_field "priority")
    PRIORITY_SHORT=$(echo "$PRIORITY_VAL" | grep -oE "^P[0-3]" || true)
    if [[ -z "$PRIORITY_SHORT" ]]; then
        WARNINGS+=("priority '$PRIORITY_VAL' should be P0|P1|P2|P3")
    fi
fi

# --- Validate status values (for results) ---
if has_field "status"; then
    STATUS_VAL=$(get_field "status")
    if ! echo "completed failed blocked timeout" | grep -qw "$STATUS_VAL"; then
        WARNINGS+=("status '$STATUS_VAL' should be completed|failed|blocked|timeout")
    fi
fi

# --- Output ---
FILENAME=$(basename "$TASK_FILE")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${RED}FAIL${NC}: $FILENAME"
    echo "  Type: $MSG_TYPE"
    echo "  Missing required fields:"
    for m in "${MISSING[@]}"; do
        echo "    - $m"
    done
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo "  Warnings:"
        for w in "${WARNINGS[@]}"; do
            echo "    - $w"
        done
    fi
    exit 1
fi

echo -e "${GREEN}PASS${NC}: $FILENAME"
echo "  Type: $MSG_TYPE"
echo "  From: $FROM_VAL → To: $TO_VAL"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo "  Warnings:"
    for w in "${WARNINGS[@]}"; do
        echo "    - $w"
    done
fi

exit 0
