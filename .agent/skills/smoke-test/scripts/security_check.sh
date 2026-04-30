#!/bin/bash
# security_check.sh - Performs basic security checks on the deployed application
# Validates SSL/TLS configuration, exposed ports, and security headers

set -euo pipefail

# Source common utilities if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
  source "${SCRIPT_DIR}/utils.sh"
fi

# Configuration
BACKEND_URL="${BACKEND_URL:-http://localhost:8000}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
TIMEOUT="${CHECK_TIMEOUT:-10}"
PASS=0
FAIL=0
WARN=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
log_info() { echo -e "[INFO] $1"; }

echo "======================================="
echo " Security Check"
echo " Target: ${BACKEND_URL}"
echo "======================================="
echo ""

# Check 1: Verify security headers on backend
log_info "Checking security headers on backend..."
HEADERS=$(curl -sI --max-time "${TIMEOUT}" "${BACKEND_URL}/health" 2>/dev/null || true)

if echo "${HEADERS}" | grep -qi "x-content-type-options"; then
  log_pass "X-Content-Type-Options header present"
else
  log_warn "X-Content-Type-Options header missing"
fi

if echo "${HEADERS}" | grep -qi "x-frame-options"; then
  log_pass "X-Frame-Options header present"
else
  log_warn "X-Frame-Options header missing"
fi

if echo "${HEADERS}" | grep -qi "strict-transport-security"; then
  log_pass "HSTS header present"
else
  log_warn "HSTS header missing (expected if not using HTTPS)"
fi

# Check 2: Ensure debug endpoints are not exposed
log_info "Checking for exposed debug endpoints..."
DEBUG_ENDPOINTS=("/debug" "/admin" "/.env" "/config" "/swagger" "/docs")
for endpoint in "${DEBUG_ENDPOINTS[@]}"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" \
    "${BACKEND_URL}${endpoint}" 2>/dev/null || echo "000")
  if [[ "${STATUS}" == "200" ]]; then
    log_warn "Potentially sensitive endpoint accessible: ${endpoint} (HTTP ${STATUS})"
  else
    log_pass "Endpoint ${endpoint} not openly accessible (HTTP ${STATUS})"
  fi
done

# Check 3: Verify no sensitive environment variables are leaked via API
log_info "Checking for sensitive data exposure in API responses..."
API_RESPONSE=$(curl -s --max-time "${TIMEOUT}" "${BACKEND_URL}/health" 2>/dev/null || echo "{}")
SENSITIVE_PATTERNS=("password" "secret" "api_key" "token" "private_key")
for pattern in "${SENSITIVE_PATTERNS[@]}"; do
  if echo "${API_RESPONSE}" | grep -qi "${pattern}"; then
    log_fail "Potentially sensitive data pattern '${pattern}' found in health response"
  else
    log_pass "No '${pattern}' pattern leaked in health response"
  fi
done

# Check 4: Validate CORS configuration
log_info "Checking CORS configuration..."
CORS_RESPONSE=$(curl -sI --max-time "${TIMEOUT}" \
  -H "Origin: http://malicious-site.example.com" \
  "${BACKEND_URL}/health" 2>/dev/null || true)

if echo "${CORS_RESPONSE}" | grep -qi "access-control-allow-origin: \*"; then
  log_warn "CORS allows all origins (*) — acceptable for dev, review for production"
elif echo "${CORS_RESPONSE}" | grep -qi "access-control-allow-origin"; then
  ORIGIN_VALUE=$(echo "${CORS_RESPONSE}" | grep -i "access-control-allow-origin" | awk '{print $2}' | tr -d '\r')
  log_pass "CORS origin restricted to: ${ORIGIN_VALUE}"
else
  log_pass "No wildcard CORS header detected for untrusted origin"
fi

# Check 5: Verify no common default credentials work
log_info "Checking default credential exposure..."
AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" \
  -u "admin:admin" "${BACKEND_URL}/api/v1/users" 2>/dev/null || echo "000")
if [[ "${AUTH_STATUS}" == "200" ]]; then
  log_fail "Default credentials (admin:admin) appear to work on /api/v1/users"
else
  log_pass "Default credentials rejected (HTTP ${AUTH_STATUS})"
fi

# Summary
echo ""
echo "======================================="
echo " Security Check Summary"
echo "======================================="
echo -e " ${GREEN}PASS${NC}: ${PASS}"
echo -e " ${YELLOW}WARN${NC}: ${WARN}"
echo -e " ${RED}FAIL${NC}: ${FAIL}"
echo ""

if [[ ${FAIL} -gt 0 ]]; then
  echo -e "${RED}Security check completed with ${FAIL} failure(s). Review findings above.${NC}"
  exit 1
elif [[ ${WARN} -gt 0 ]]; then
  echo -e "${YELLOW}Security check completed with ${WARN} warning(s). Review before production.${NC}"
  exit 0
else
  echo -e "${GREEN}All security checks passed.${NC}"
  exit 0
fi
