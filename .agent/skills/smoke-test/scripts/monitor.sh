#!/bin/bash
# monitor.sh - Continuous monitoring script for smoke test health checks
# Polls service endpoints and reports status changes during test runs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load shared configuration
# shellcheck source=../references/SOP.md
BACKEND_URL="${BACKEND_URL:-http://localhost:8000}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-5}"
MONITOR_DURATION="${MONITOR_DURATION:-60}"
LOG_FILE="${LOG_FILE:-/tmp/deer-flow-monitor.log}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# State tracking
consecutive_failures=0
last_status="unknown"
start_time=$(date +%s)

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

check_endpoint() {
    local url="$1"
    local name="$2"
    local http_code
    local response_time

    response_time=$(date +%s%3N)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 \
        --max-time 10 \
        "${url}/health" 2>/dev/null || echo "000")
    response_time=$(( $(date +%s%3N) - response_time ))

    if [[ "${http_code}" =~ ^2 ]]; then
        echo -e "  ${GREEN}✓${NC} ${name}: HTTP ${http_code} (${response_time}ms)"
        log "INFO" "${name} healthy: HTTP ${http_code} (${response_time}ms)"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${name}: HTTP ${http_code} (${response_time}ms)"
        log "WARN" "${name} unhealthy: HTTP ${http_code} (${response_time}ms)"
        return 1
    fi
}

check_all_services() {
    local all_healthy=true

    echo -e "\n${BLUE}[$(date '+%H:%M:%S')]${NC} Checking services..."

    check_endpoint "${BACKEND_URL}" "Backend" || all_healthy=false
    check_endpoint "${FRONTEND_URL}" "Frontend" || all_healthy=false

    if ${all_healthy}; then
        return 0
    else
        return 1
    fi
}

handle_failure() {
    consecutive_failures=$(( consecutive_failures + 1 ))
    log "ERROR" "Service check failed (consecutive: ${consecutive_failures}/${FAILURE_THRESHOLD})"

    if [[ ${consecutive_failures} -ge ${FAILURE_THRESHOLD} ]]; then
        echo -e "\n${RED}ALERT: ${FAILURE_THRESHOLD} consecutive failures detected!${NC}"
        log "CRITICAL" "Failure threshold reached — triggering notification"

        if [[ -x "${SCRIPT_DIR}/notify.sh" ]]; then
            NOTIFY_MESSAGE="Smoke test monitor: ${FAILURE_THRESHOLD} consecutive health check failures" \
                "${SCRIPT_DIR}/notify.sh" || true
        fi

        consecutive_failures=0  # Reset after alert
    fi
}

print_summary() {
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    echo -e "\n${BLUE}=== Monitor Session Summary ===${NC}"
    echo "  Duration:  ${duration}s"
    echo "  Log file:  ${LOG_FILE}"
    log "INFO" "Monitor session ended after ${duration}s"
}

main() {
    echo -e "${BLUE}=== DeerFlow Service Monitor ===${NC}"
    echo "  Backend:   ${BACKEND_URL}"
    echo "  Frontend:  ${FRONTEND_URL}"
    echo "  Interval:  ${MONITOR_INTERVAL}s"
    echo "  Duration:  ${MONITOR_DURATION}s"
    echo "  Log:       ${LOG_FILE}"
    echo ""

    log "INFO" "Monitor started (interval=${MONITOR_INTERVAL}s, duration=${MONITOR_DURATION}s)"

    trap 'print_summary; exit 0' INT TERM

    while true; do
        current_time=$(date +%s)
        elapsed=$(( current_time - start_time ))

        if [[ ${elapsed} -ge ${MONITOR_DURATION} ]]; then
            echo -e "\n${YELLOW}Monitor duration (${MONITOR_DURATION}s) reached.${NC}"
            break
        fi

        if check_all_services; then
            consecutive_failures=0
            last_status="healthy"
        else
            handle_failure
            last_status="unhealthy"
        fi

        sleep "${MONITOR_INTERVAL}"
    done

    print_summary

    if [[ "${last_status}" == "unhealthy" ]]; then
        exit 1
    fi
}

main "$@"
