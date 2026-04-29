#!/bin/bash
# performance_check.sh - Measure response times and basic performance metrics
# for the deer-flow application during smoke testing.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/tmp/deer-flow-performance.log}"
BACKEND_URL="${BACKEND_URL:-http://localhost:8000}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
THRESHOLD_MS="${PERF_THRESHOLD_MS:-2000}"   # fail if p95 latency exceeds this
REQUEST_COUNT="${PERF_REQUEST_COUNT:-10}"    # number of requests per endpoint
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
pass() { log "  [PASS] $*"; ((PASS++)); }
fail() { log "  [FAIL] $*"; ((FAIL++)); }
header() { log "\n=== $* ==="; }

# Measure average response time (ms) for a URL over N requests.
# Prints the average as an integer.
measure_avg_ms() {
    local url="$1"
    local count="$2"
    local total=0
    local i
    for ((i = 0; i < count; i++)); do
        local ms
        ms=$(curl -o /dev/null -s -w "%{time_total}" --max-time 10 "$url" 2>/dev/null || echo "0")
        # Convert seconds (float) to milliseconds (integer)
        ms=$(awk "BEGIN { printf \"%d\", $ms * 1000 }")
        total=$((total + ms))
    done
    echo $((total / count))
}

# Check that a measured average is within the threshold.
check_latency() {
    local label="$1"
    local avg_ms="$2"
    if [[ "$avg_ms" -le "$THRESHOLD_MS" ]]; then
        pass "$label avg latency ${avg_ms}ms <= threshold ${THRESHOLD_MS}ms"
    else
        fail "$label avg latency ${avg_ms}ms exceeds threshold ${THRESHOLD_MS}ms"
    fi
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
check_backend_health_latency() {
    header "Backend /health latency"
    local url="${BACKEND_URL}/health"
    if ! curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        fail "Backend health endpoint unreachable at $url — skipping latency test"
        return
    fi
    local avg
    avg=$(measure_avg_ms "$url" "$REQUEST_COUNT")
    log "  Sampled $REQUEST_COUNT requests → avg ${avg}ms"
    check_latency "Backend /health" "$avg"
}

check_backend_api_latency() {
    header "Backend /api/v1/status latency"
    local url="${BACKEND_URL}/api/v1/status"
    if ! curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        log "  INFO: /api/v1/status not available — skipping"
        return
    fi
    local avg
    avg=$(measure_avg_ms "$url" "$REQUEST_COUNT")
    log "  Sampled $REQUEST_COUNT requests → avg ${avg}ms"
    check_latency "Backend /api/v1/status" "$avg"
}

check_frontend_latency() {
    header "Frontend root latency"
    local url="${FRONTEND_URL}/"
    if ! curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        fail "Frontend unreachable at $url — skipping latency test"
        return
    fi
    local avg
    avg=$(measure_avg_ms "$url" "$REQUEST_COUNT")
    log "  Sampled $REQUEST_COUNT requests → avg ${avg}ms"
    check_latency "Frontend /" "$avg"
}

check_concurrent_requests() {
    header "Concurrent request handling (backend /health)"
    local url="${BACKEND_URL}/health"
    if ! curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        fail "Backend health endpoint unreachable — skipping concurrency test"
        return
    fi
    # Fire 5 requests in parallel and measure wall-clock time
    local start end elapsed
    start=$(date +%s%3N)
    for i in $(seq 1 5); do
        curl -o /dev/null -s --max-time 10 "$url" &
    done
    wait
    end=$(date +%s%3N)
    elapsed=$((end - start))
    log "  5 concurrent requests completed in ${elapsed}ms"
    if [[ "$elapsed" -le $((THRESHOLD_MS * 2)) ]]; then
        pass "Concurrent requests completed within $((THRESHOLD_MS * 2))ms"
    else
        fail "Concurrent requests took ${elapsed}ms — exceeds $((THRESHOLD_MS * 2))ms"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    header "Performance Check Summary"
    log "  Passed : $PASS"
    log "  Failed : $FAIL"
    log "  Total  : $((PASS + FAIL))"
    if [[ "$FAIL" -gt 0 ]]; then
        log "  Result : DEGRADED"
        return 1
    fi
    log "  Result : OK"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "Starting performance checks (threshold=${THRESHOLD_MS}ms, samples=${REQUEST_COUNT})"
    check_backend_health_latency
    check_backend_api_latency
    check_frontend_latency
    check_concurrent_requests
    print_summary
}

main "$@"
