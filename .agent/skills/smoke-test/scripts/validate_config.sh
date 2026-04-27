#!/usr/bin/env bash
# validate_config.sh — Validates required configuration files and environment variables
# for the deer-flow application before running smoke tests.
#
# Usage: ./validate_config.sh [--strict]
#   --strict: Treat warnings as errors

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

STRICT_MODE=false
ERRORS=0
WARNINGS=0

# Parse arguments
for arg in "$@"; do
  case $arg in
    --strict)
      STRICT_MODE=true
      ;;
  esac
done

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; ((WARNINGS++)) || true; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; ((ERRORS++)) || true; }

# ── Required config files ────────────────────────────────────────────────────
check_required_files() {
  log_info "Checking required configuration files..."

  local required_files=(
    ".env"
    "conf.yaml"
  )

  local optional_files=(
    ".env.local"
    "docker-compose.yml"
    "docker-compose.override.yml"
  )

  for f in "${required_files[@]}"; do
    if [[ -f "${PROJECT_ROOT}/${f}" ]]; then
      log_ok "Found required file: ${f}"
    else
      log_error "Missing required file: ${f} (expected at ${PROJECT_ROOT}/${f})"
    fi
  done

  for f in "${optional_files[@]}"; do
    if [[ -f "${PROJECT_ROOT}/${f}" ]]; then
      log_ok "Found optional file: ${f}"
    else
      log_warn "Optional file not found: ${f}"
    fi
  done
}

# ── Required environment variables ──────────────────────────────────────────
check_env_vars() {
  log_info "Checking required environment variables..."

  # Load .env if present
  local env_file="${PROJECT_ROOT}/.env"
  if [[ -f "${env_file}" ]]; then
    # Export vars without executing arbitrary code
    set -o allexport
    # shellcheck disable=SC1090
    source "${env_file}"
    set +o allexport
  fi

  local required_vars=(
    "OPENAI_API_KEY"
  )

  local recommended_vars=(
    "TAVILY_API_KEY"
    "LANGCHAIN_API_KEY"
    "LANGCHAIN_TRACING_V2"
  )

  for var in "${required_vars[@]}"; do
    if [[ -n "${!var:-}" ]]; then
      log_ok "${var} is set"
    else
      log_error "${var} is not set (required)"
    fi
  done

  for var in "${recommended_vars[@]}"; do
    if [[ -n "${!var:-}" ]]; then
      log_ok "${var} is set"
    else
      log_warn "${var} is not set (recommended but optional)"
    fi
  done
}

# ── conf.yaml basic structure check ─────────────────────────────────────────
check_conf_yaml() {
  local conf="${PROJECT_ROOT}/conf.yaml"
  [[ -f "${conf}" ]] || return 0  # already reported as missing above

  log_info "Validating conf.yaml structure..."

  if command -v python3 &>/dev/null; then
    python3 - <<'PYEOF' "${conf}"
import sys, yaml, pathlib
conf_path = pathlib.Path(sys.argv[1])
try:
    data = yaml.safe_load(conf_path.read_text())
    if not isinstance(data, dict):
        print("ERROR: conf.yaml root must be a mapping", file=sys.stderr)
        sys.exit(1)
    print("OK: conf.yaml is valid YAML")
except yaml.YAMLError as e:
    print(f"ERROR: conf.yaml parse error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    if [[ $? -eq 0 ]]; then
      log_ok "conf.yaml is valid YAML"
    else
      log_error "conf.yaml contains invalid YAML"
    fi
  else
    log_warn "python3 not available; skipping YAML validation of conf.yaml"
  fi
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo "────────────────────────────────────────"
  echo -e " Config validation summary"
  echo "────────────────────────────────────────"
  echo -e " ${GREEN}OK${NC}       checks passed"
  echo -e " ${RED}Errors:${NC}   ${ERRORS}"
  echo -e " ${YELLOW}Warnings:${NC} ${WARNINGS}"
  echo "────────────────────────────────────────"

  if [[ "${STRICT_MODE}" == true && "${WARNINGS}" -gt 0 ]]; then
    log_error "Strict mode: treating ${WARNINGS} warning(s) as error(s)."
    ((ERRORS += WARNINGS)) || true
  fi

  if [[ "${ERRORS}" -gt 0 ]]; then
    echo -e "${RED}Configuration validation FAILED.${NC}"
    exit 1
  else
    echo -e "${GREEN}Configuration validation PASSED.${NC}"
    exit 0
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo ""
  log_info "Starting configuration validation for deer-flow"
  log_info "Project root: ${PROJECT_ROOT}"
  [[ "${STRICT_MODE}" == true ]] && log_info "Strict mode enabled"
  echo ""

  check_required_files
  echo ""
  check_env_vars
  echo ""
  check_conf_yaml

  print_summary
}

main
