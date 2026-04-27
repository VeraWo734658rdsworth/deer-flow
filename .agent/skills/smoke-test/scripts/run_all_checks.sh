#!/bin/bash
# run_all_checks.sh — Master smoke-test runner for deer-flow
# Executes all individual check/deploy scripts in sequence and
# produces a consolidated pass/fail summary.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/smoke_test_${TIMESTAMP}.log"
DEPLOY_MODE="${1:-local}"   # 'local' or 'docker'

mkdir -p "${LOG_DIR}"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Colour

pass() { echo -e "${GREEN}[PASS]${NC} $*" | tee -a "${LOG_FILE}"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" | tee -a "${LOG_FILE}"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*" | tee -a "${LOG_FILE}"; }

# ---------------------------------------------------------------------------
# Tracking
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0
FAILED_STEPS=()

run_step() {
    local label="$1"
    local script="$2"
    shift 2

    info "Running: ${label}"
    if bash "${script}" "$@" >> "${LOG_FILE}" 2>&1; then
        pass "${label}"
        PASSED=$((PASSED + 1))
    else
        fail "${label}"
        FAILED=$((FAILED + 1))
        FAILED_STEPS+=("${label}")
    fi
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo "" | tee -a "${LOG_FILE}"
info "======================================================"
info " deer-flow Smoke Test Suite  —  mode: ${DEPLOY_MODE}"
info " Started: $(date)"
info "======================================================"
echo "" | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# Step 1 — Environment pre-flight
# ---------------------------------------------------------------------------
run_step "Local environment check" "${SCRIPT_DIR}/check_local_env.sh"

# ---------------------------------------------------------------------------
# Step 2 — Docker availability (always checked; required for docker mode)
# ---------------------------------------------------------------------------
if [[ "${DEPLOY_MODE}" == "docker" ]]; then
    run_step "Docker availability check" "${SCRIPT_DIR}/check_docker.sh"
else
    info "Skipping Docker check (mode=local)"
fi

# ---------------------------------------------------------------------------
# Step 3 — Deploy backend
# ---------------------------------------------------------------------------
if [[ "${DEPLOY_MODE}" == "docker" ]]; then
    run_step "Docker deploy" "${SCRIPT_DIR}/deploy_docker.sh"
else
    run_step "Local deploy" "${SCRIPT_DIR}/deploy_local.sh"
fi

# ---------------------------------------------------------------------------
# Step 4 — Frontend health check
# ---------------------------------------------------------------------------
run_step "Frontend health check" "${SCRIPT_DIR}/frontend_check.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" | tee -a "${LOG_FILE}"
info "======================================================"
info " Results:  ${PASSED} passed  |  ${FAILED} failed"
info " Log:      ${LOG_FILE}"
info "======================================================"

if [[ ${FAILED} -gt 0 ]]; then
    fail "Failed steps:"
    for step in "${FAILED_STEPS[@]}"; do
        fail "  • ${step}"
    done
    echo "" | tee -a "${LOG_FILE}"
    exit 1
fi

pass "All smoke-test steps completed successfully."
exit 0
