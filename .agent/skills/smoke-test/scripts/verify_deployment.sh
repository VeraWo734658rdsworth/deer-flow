#!/bin/bash
# verify_deployment.sh - Post-deployment verification script
# Validates that the deployment is functioning correctly by running
# a series of endpoint checks, service health probes, and basic
# functional tests against the deployed deer-flow instance.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"

# Source shared utilities if available
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
  source "${SCRIPT_DIR}/utils.sh"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BACKEND_HOST="${BACKEND_HOST:-localhost}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_HOST="${FRONTEND_HOST:-localhost}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
TIMEOUT="${VERIFY_TIMEOUT:-30}"
MAX_RETRIES="${VERIFY_MAX_RETRIES:-5}"
RETRY_DELAY="${VERIFY_RETRY_DELAY:-3}"

BACKEND_URL="http://${BACKEND_HOST}:${BACKEND_PORT}"
FRONTEND_URL="http://${FRONTEND_HOST}:${FRONTEND_PORT}"

PASS=0
FAIL=0
WARN=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
pass() { log "  ✅  PASS: $*"; ((PASS++)); }
fail() { log "  ❌  FAIL: $*"; ((FAIL++)); }
warn() { log "  ⚠️   WARN: $*"; ((WARN++)); }

# Retry a curl command up to MAX_RETRIES times.
retry_curl() {
  local url="$1"
  local expected_status="${2:-200}"
  local attempt=0

  while (( attempt < MAX_RETRIES )); do
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time "${TIMEOUT}" "${url}" 2>/dev/null || echo "000")

    if [[ "${status}" == "${expected_status}" ]]; then
      return 0
    fi

    ((attempt++)) || true
    log "    Attempt ${attempt}/${MAX_RETRIES} — got HTTP ${status}, expected ${expected_status}. Retrying in ${RETRY_DELAY}s…"
    sleep "${RETRY_DELAY}"
  done
  return 1
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
check_backend_health() {
  log "Checking backend health endpoint…"
  if retry_curl "${BACKEND_URL}/health" "200"; then
    pass "Backend /health returned 200"
  else
    fail "Backend /health did not return 200 after ${MAX_RETRIES} attempts"
  fi
}

check_backend_api_docs() {
  log "Checking backend API docs availability…"
  if retry_curl "${BACKEND_URL}/docs" "200"; then
    pass "Backend /docs is accessible"
  else
    warn "Backend /docs not accessible (non-critical)"
  fi
}

check_frontend_reachable() {
  log "Checking frontend reachability…"
  if retry_curl "${FRONTEND_URL}/" "200"; then
    pass "Frontend root returned 200"
  else
    fail "Frontend root did not return 200 after ${MAX_RETRIES} attempts"
  fi
}

check_backend_version() {
  log "Checking backend version endpoint…"
  local response
  response=$(curl -s --max-time "${TIMEOUT}" "${BACKEND_URL}/version" 2>/dev/null || echo "")
  if echo "${response}" | grep -qE '"version"'; then
    pass "Backend /version returned a version payload"
  else
    warn "Backend /version did not return expected JSON (endpoint may not exist)"
  fi
}

check_config_endpoint() {
  log "Checking backend config endpoint…"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" "${BACKEND_URL}/api/config" 2>/dev/null || echo "000")
  if [[ "${status}" =~ ^(200|401|403)$ ]]; then
    pass "Backend /api/config responded with HTTP ${status} (auth-gated is acceptable)"
  else
    fail "Backend /api/config returned unexpected HTTP ${status}"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=================================================================="
  log " deer-flow Deployment Verification"
  log "  Backend  : ${BACKEND_URL}"
  log "  Frontend : ${FRONTEND_URL}"
  log "=================================================================="

  check_backend_health
  check_backend_api_docs
  check_backend_version
  check_config_endpoint
  check_frontend_reachable

  log "------------------------------------------------------------------"
  log " Results — PASS: ${PASS}  FAIL: ${FAIL}  WARN: ${WARN}"
  log "------------------------------------------------------------------"

  if (( FAIL > 0 )); then
    log "Deployment verification FAILED. Review errors above."
    exit 1
  else
    log "Deployment verification PASSED."
    exit 0
  fi
}

main "$@"
