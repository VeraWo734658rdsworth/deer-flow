#!/bin/bash
# report_results.sh - Aggregate and report smoke test results
# Collects outputs from all check scripts and generates a summary report

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${REPORT_DIR:-/tmp/deer-flow-smoke-test}"
REPORT_FILE="${REPORT_DIR}/report_$(date +%Y%m%d_%H%M%S).txt"
SUMMARY_FILE="${REPORT_DIR}/summary_latest.txt"
JSON_REPORT="${REPORT_DIR}/results_latest.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Colour codes (disabled if not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  GREEN='' RED='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}[REPORT]${RESET} $*"; }
pass() { echo -e "  ${GREEN}✔ PASS${RESET}  $*"; }
fail() { echo -e "  ${RED}✘ FAIL${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠ WARN${RESET}  $*"; }

mkdir -p "${REPORT_DIR}"

# ─── Result accumulators ──────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
WARNED=0
declare -a RESULTS=()

record() {
  local name="$1" status="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  case "$status" in
    PASS) PASSED=$((PASSED + 1)); pass "$name" ;;
    FAIL) FAILED=$((FAILED + 1)); fail "$name${detail:+ — $detail}" ;;
    WARN) WARNED=$((WARNED + 1)); warn "$name${detail:+ — $detail}" ;;
  esac
  RESULTS+=("{ \"name\": \"$name\", \"status\": \"$status\", \"detail\": \"$detail\" }")
}

# ─── Run individual checks and capture status ─────────────────────────────────
run_check() {
  local label="$1" script="$2"
  if [ ! -x "${SCRIPT_DIR}/${script}" ]; then
    record "$label" "WARN" "script not found or not executable: $script"
    return
  fi
  local output exit_code=0
  output=$("${SCRIPT_DIR}/${script}" 2>&1) || exit_code=$?
  if [ $exit_code -eq 0 ]; then
    record "$label" "PASS"
  else
    # Capture first error line as detail
    local detail
    detail=$(echo "$output" | grep -i 'error\|fail\|fatal' | head -1 || true)
    record "$label" "FAIL" "${detail:-exit code $exit_code}"
  fi
}

# ─── Main report logic ────────────────────────────────────────────────────────
main() {
  log "Starting smoke-test report — ${TIMESTAMP}"
  echo

  run_check "Local environment"   "check_local_env.sh"
  run_check "Docker environment"  "check_docker.sh"
  run_check "Config validation"   "validate_config.sh"
  run_check "Health check"        "health_check.sh"
  run_check "Frontend check"      "frontend_check.sh"

  # ── Write plain-text report ────────────────────────────────────────────────
  {
    echo "====================================================="
    echo " DeerFlow Smoke-Test Report"
    echo " Generated : ${TIMESTAMP}"
    echo " Host      : $(hostname)"
    echo "====================================================="
    echo
    echo "Results:"
    for r in "${RESULTS[@]}"; do
      status=$(echo "$r" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
      name=$(echo "$r"   | grep -o '"name": "[^"]*"'   | cut -d'"' -f4)
      detail=$(echo "$r" | grep -o '"detail": "[^"]*"' | cut -d'"' -f4)
      printf "  [%-4s] %s%s\n" "$status" "$name" "${detail:+  ($detail)}"
    done
    echo
    echo "Summary: ${PASSED}/${TOTAL} passed, ${FAILED} failed, ${WARNED} warnings"
    echo "====================================================="
  } | tee "${REPORT_FILE}" > "${SUMMARY_FILE}"

  # ── Write JSON report ──────────────────────────────────────────────────────
  {
    echo "{"
    echo "  \"timestamp\": \"${TIMESTAMP}\","
    echo "  \"host\": \"$(hostname)\","
    echo "  \"summary\": { \"total\": ${TOTAL}, \"passed\": ${PASSED}, \"failed\": ${FAILED}, \"warned\": ${WARNED} },"
    echo "  \"results\": ["
    local last=$((${#RESULTS[@]} - 1))
    for i in "${!RESULTS[@]}"; do
      if [ $i -lt $last ]; then
        echo "    ${RESULTS[$i]},"
      else
        echo "    ${RESULTS[$i]}"
      fi
    done
    echo "  ]"
    echo "}"
  } > "${JSON_REPORT}"

  echo
  log "Report saved to : ${REPORT_FILE}"
  log "JSON report     : ${JSON_REPORT}"
  echo

  # ── Final exit code ────────────────────────────────────────────────────────
  if [ "${FAILED}" -gt 0 ]; then
    echo -e "${RED}${BOLD}SMOKE TEST FAILED — ${FAILED} check(s) did not pass.${RESET}"
    exit 1
  else
    echo -e "${GREEN}${BOLD}SMOKE TEST PASSED — all ${PASSED} checks OK.${RESET}"
    exit 0
  fi
}

main "$@"
