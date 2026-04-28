#!/bin/bash
# health_check.sh - Verify that all services are healthy after deployment
# Part of the deer-flow smoke-test skill
#
# Usage: ./health_check.sh [--mode local|docker] [--timeout 60] [--verbose]

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODE="local"
TIMEOUT=60
VERBOSE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colour helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { $VERBOSE && echo -e "[INFO] $*" || true; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      MODE="$2";    shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --verbose)   VERBOSE=true; shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Configuration — override via environment variables if needed
# ---------------------------------------------------------------------------
BACKEND_URL="${BACKEND_URL:-http://localhost:8000}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/health}"

FAILURES=0

# ---------------------------------------------------------------------------
# Helper: poll a URL until HTTP 200 or timeout
# ---------------------------------------------------------------------------
wait_for_http() {
  local label="$1"
  local url="$2"
  local deadline=$(( $(date +%s) + TIMEOUT ))

  info "Polling $url (timeout ${TIMEOUT}s)"
  while true; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
      pass "$label is healthy (HTTP $code)"
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      fail "$label did not become healthy within ${TIMEOUT}s (last HTTP $code)"
      FAILURES=$(( FAILURES + 1 ))
      return 1
    fi
    info "  $label → HTTP $code, retrying…"
    sleep 3
  done
}

# ---------------------------------------------------------------------------
# Helper: check a docker container is running
# ---------------------------------------------------------------------------
check_container() {
  local name="$1"
  local status
  status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
  if [[ "$status" == "running" ]]; then
    pass "Container '$name' is running"
  else
    fail "Container '$name' status: $status"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

# ---------------------------------------------------------------------------
# Main checks
# ---------------------------------------------------------------------------
echo "======================================="
echo " deer-flow Health Check  [mode: $MODE]"
echo "======================================="

# 1. Backend API health
wait_for_http "Backend API" "${BACKEND_URL}${HEALTH_ENDPOINT}"

# 2. Frontend
wait_for_http "Frontend" "${FRONTEND_URL}"

# 3. Docker-specific container checks
if [[ "$MODE" == "docker" ]]; then
  echo ""
  echo "--- Docker container status ---"
  check_container "deerflow-backend"
  check_container "deerflow-frontend"
fi

# 4. Quick API smoke — expect JSON body with a recognisable key
echo ""
echo "--- API smoke probe ---"
API_BODY=$(curl -s --max-time 10 "${BACKEND_URL}${HEALTH_ENDPOINT}" 2>/dev/null || echo "{}")
if echo "$API_BODY" | grep -qiE '"status"\s*:\s*"ok"|"healthy"\s*:\s*true'; then
  pass "Backend health response contains expected status field"
else
  warn "Backend health response did not contain expected status field — body: $API_BODY"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================="
if [[ $FAILURES -eq 0 ]]; then
  pass "All health checks passed."
  exit 0
else
  fail "$FAILURES health check(s) failed."
  exit 1
fi
