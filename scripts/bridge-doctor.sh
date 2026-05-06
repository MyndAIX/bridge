#!/bin/bash
# bridge-doctor.sh — MyndAIX Bridge Health Diagnostic
# Comprehensive health check for all bridge infrastructure components
# Usage: bridge-doctor.sh [--json]

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ── Configuration ─────────────────────────────────────────────────────────
BRIDGE_ROOT="$HOME/.myndaix/bridge"
INBOX_ROOT="$BRIDGE_ROOT/inbox"
LOCKS_ROOT="$BRIDGE_ROOT/locks"
STATE_ROOT="$BRIDGE_ROOT/state"

# Machine detection
MACHINE_ID=$([ "$(whoami)" = "stevenfernandez" ] && echo "macbook" || echo "mini")

# Output control
JSON_OUTPUT=false
if [[ "${1:-}" == "--json" ]]; then
    JSON_OUTPUT=true
fi

# Exit status tracking
EXIT_CODE=0
CHECKS_PASSED=0
CHECKS_WARNED=0
CHECKS_FAILED=0

# ── Output Functions ──────────────────────────────────────────────────────
if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "{"
    echo '  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'
    echo '  "machine": "'$MACHINE_ID'",'
    echo '  "checks": ['
    FIRST_CHECK=true
fi

# Colors for terminal output
if [[ "$JSON_OUTPUT" == "false" && ( -t 1 || -n "${FORCE_COLOR:-}" ) ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
    BOLD='\033[1m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
    BOLD=''
fi

check_result() {
    local name="$1"
    local status="$2"
    local message="$3"
    local fix_command="${4:-}"

    case "$status" in
        "PASS")
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
            ;;
        "WARN")
            CHECKS_WARNED=$((CHECKS_WARNED + 1))
            ;;
        "FAIL")
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
            EXIT_CODE=1
            ;;
    esac

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        [[ "$FIRST_CHECK" == "false" ]] && echo ","
        FIRST_CHECK=false
        echo "    {"
        echo "      \"name\": \"$name\","
        echo "      \"status\": \"$status\","
        echo "      \"message\": \"$message\""
        [[ -n "$fix_command" ]] && echo ",      \"fix\": \"$fix_command\""
        echo -n "    }"
    else
        local color=""
        case "$status" in
            "PASS") color="$GREEN" ;;
            "WARN") color="$YELLOW" ;;
            "FAIL") color="$RED" ;;
        esac

        printf "%-30s %s%s%s  %s\n" "$name" "$color" "$status" "$NC" "$message"
        [[ -n "$fix_command" && "$status" == "FAIL" ]] &&
            printf "  ${BLUE}Fix:${NC} %s\n" "$fix_command"
    fi
}

header() {
    [[ "$JSON_OUTPUT" == "false" ]] &&
        echo -e "${BOLD}${BLUE}Bridge Doctor v1.0 — $MACHINE_ID${NC}\n"
}

# ── Health Check Functions ────────────────────────────────────────────────

check_daemon() {
    local daemon_pid=$(pgrep -f 'myndaix-daemon.js' 2>/dev/null | head -1)

    if [[ -n "$daemon_pid" ]]; then
        check_result "daemon" "PASS" "Running (PID: $daemon_pid)"
    else
        check_result "daemon" "FAIL" "Not running" \
            "cd $BRIDGE_ROOT && node myndaix-daemon.js &"
    fi
}

check_watchers() {
    local watchers=()
    if [[ "$MACHINE_ID" == "macbook" ]]; then
        watchers=("mack")
    else
        watchers=("mini" "antman" "kilabz" "recon" "oracle" "harley")
    fi

    for watcher in "${watchers[@]}"; do
        local agent_name="ai.myndaix.${watcher}-watcher"
        local status=$(launchctl list | grep "$agent_name" 2>/dev/null || echo "")

        if [[ -n "$status" ]]; then
            local pid=$(echo "$status" | awk '{print $1}')
            if [[ "$pid" != "-" ]]; then
                check_result "watcher-$watcher" "PASS" "Running (PID: $pid)"
            else
                check_result "watcher-$watcher" "WARN" "Loaded but not running" \
                    "launchctl kickstart -k gui/\$(id -u)/$agent_name"
            fi
        else
            check_result "watcher-$watcher" "FAIL" "LaunchAgent not loaded" \
                "launchctl load ~/Library/LaunchAgents/$agent_name.plist"
        fi
    done
}

check_inbox_freshness() {
    local stale_count=0
    local total_files=0

    for agent_dir in "$INBOX_ROOT"/*; do
        [[ -d "$agent_dir" ]] || continue
        local agent=$(basename "$agent_dir")

        while IFS= read -r -d '' file; do
            total_files=$((total_files + 1))
            if [[ $(find "$file" -mmin +30 2>/dev/null) ]]; then
                stale_count=$((stale_count + 1))
            fi
        done < <(find "$agent_dir" -name "*.md" -type f -print0 2>/dev/null)
    done

    if [[ $stale_count -eq 0 ]]; then
        check_result "inbox-freshness" "PASS" "All files fresh ($total_files files)"
    elif [[ $stale_count -lt 10 ]]; then
        check_result "inbox-freshness" "WARN" "$stale_count stale files (>30min old)" \
            "find $INBOX_ROOT -name '*.md' -mmin +30 -exec rm {} +"
    else
        check_result "inbox-freshness" "FAIL" "$stale_count stale files (cleanup needed)" \
            "find $INBOX_ROOT -name '*.md' -mmin +30 -exec rm {} +"
    fi
}

check_locks() {
    local stale_locks=$(find "$LOCKS_ROOT" -name "*.lock" -mmin +60 2>/dev/null | wc -l)

    if [[ $stale_locks -eq 0 ]]; then
        check_result "locks" "PASS" "No stale locks"
    else
        check_result "locks" "FAIL" "$stale_locks stale lock files (>60min old)" \
            "find $LOCKS_ROOT -name '*.lock' -mmin +60 -exec rm -rf {} +"
    fi
}

check_syncthing() {
    local status_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 \
        http://localhost:8384/ 2>/dev/null || echo "000")

    if [[ "$status_code" == "200" ]]; then
        check_result "syncthing" "PASS" "API responding"
    else
        check_result "syncthing" "FAIL" "API not responding (HTTP: $status_code)" \
            "brew services restart syncthing"
    fi
}

check_secrets() {
    local missing_secrets=()

    # Check Discord webhook
    if [[ ! -f "$HOME/.myndaix/discord/.env" ]] || ! grep -q "DISCORD_WEBHOOK" "$HOME/.myndaix/discord/.env" 2>/dev/null; then
        missing_secrets+=("DISCORD_WEBHOOK")
    fi

    # Check OpenClaw config
    if [[ ! -f "$HOME/.openclaw/config.json" ]]; then
        missing_secrets+=("OPENCLAW_CONFIG")
    fi

    # Check Claude API key
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ ! -f "$HOME/.anthropic" ]]; then
        missing_secrets+=("ANTHROPIC_API_KEY")
    fi

    if [[ ${#missing_secrets[@]} -eq 0 ]]; then
        check_result "secrets" "PASS" "All required secrets present"
    else
        local missing_str=$(IFS=', '; echo "${missing_secrets[*]}")
        check_result "secrets" "FAIL" "Missing: $missing_str" \
            "Check ~/.myndaix/discord/.env, ~/.openclaw/config.json, ~/.anthropic"
    fi
}

check_proxy_chain() {
    local proxy_3456=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 \
        http://localhost:3456/v1/models 2>/dev/null || echo "000")
    local proxy_3457=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 \
        http://localhost:3457/v1/models 2>/dev/null || echo "000")

    local failed_proxies=()
    [[ "$proxy_3456" != "200" ]] && failed_proxies+=("3456")
    [[ "$proxy_3457" != "200" ]] && failed_proxies+=("3457")

    if [[ ${#failed_proxies[@]} -eq 0 ]]; then
        check_result "proxy-chain" "PASS" "All proxies responding"
    elif [[ ${#failed_proxies[@]} -eq 1 ]]; then
        check_result "proxy-chain" "WARN" "Port ${failed_proxies[0]} not responding" \
            "Check proxy processes on port ${failed_proxies[0]}"
    else
        local failed_str=$(IFS=', '; echo "${failed_proxies[*]}")
        check_result "proxy-chain" "FAIL" "Ports $failed_str not responding" \
            "Restart proxy services on ports $failed_str"
    fi
}

check_auth_tokens() {
    # Check OpenClaw gateway health (proxy for auth validity)
    local gw_status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 \
        http://127.0.0.1:18789/ 2>/dev/null || echo "000")

    if [[ "$gw_status" == "200" ]] || [[ "$gw_status" == "404" ]]; then
        check_result "auth-tokens" "PASS" "Gateway responding (auth valid)"
    else
        check_result "auth-tokens" "FAIL" "Gateway not responding (auth may be invalid)" \
            "Check OpenClaw gateway logs and restart if needed"
    fi
}

# ── Main Execution ────────────────────────────────────────────────────────

main() {
    header

    check_daemon
    check_watchers
    check_inbox_freshness
    check_locks
    check_syncthing
    check_secrets
    check_proxy_chain
    check_auth_tokens

    # Output summary
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo ""
        echo "  ],"
        echo '  "summary": {'
        echo "    \"passed\": $CHECKS_PASSED,"
        echo "    \"warned\": $CHECKS_WARNED,"
        echo "    \"failed\": $CHECKS_FAILED,"
        echo "    \"exit_code\": $EXIT_CODE"
        echo "  }"
        echo "}"
    else
        echo ""
        local total=$((CHECKS_PASSED + CHECKS_WARNED + CHECKS_FAILED))
        echo -e "${BOLD}Summary:${NC} $total checks"
        echo -e "  ${GREEN}✓ $CHECKS_PASSED passed${NC}"
        [[ $CHECKS_WARNED -gt 0 ]] && echo -e "  ${YELLOW}⚠ $CHECKS_WARNED warned${NC}"
        [[ $CHECKS_FAILED -gt 0 ]] && echo -e "  ${RED}✗ $CHECKS_FAILED failed${NC}"

        if [[ $EXIT_CODE -eq 0 ]]; then
            echo -e "\n${GREEN}${BOLD}Bridge health: OK${NC}"
        else
            echo -e "\n${RED}${BOLD}Bridge health: CRITICAL${NC}"
        fi
    fi

    exit $EXIT_CODE
}

# Execute main function
main "$@"