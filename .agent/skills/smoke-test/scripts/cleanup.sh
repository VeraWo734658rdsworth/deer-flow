#!/usr/bin/env bash
# cleanup.sh - Clean up smoke test artifacts, temporary files, and optionally stop services
#
# Usage:
#   ./cleanup.sh [OPTIONS]
#
# Options:
#   --docker      Stop and remove Docker containers/networks created during smoke test
#   --logs        Remove log files generated during smoke test
#   --all         Perform all cleanup actions
#   --dry-run     Show what would be cleaned without actually doing it
#   -h, --help    Show this help message

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colour

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Defaults ─────────────────────────────────────────────────────────────────
CLEAN_DOCKER=false
CLEAN_LOGS=false
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/.agent/logs"
TMP_DIR="${PROJECT_ROOT}/.agent/tmp"

# Docker labels/names used by the smoke-test deploy scripts
DOCKER_COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"
DOCKER_PROJECT_NAME="deer-flow"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker)  CLEAN_DOCKER=true ;;
    --logs)    CLEAN_LOGS=true ;;
    --all)     CLEAN_DOCKER=true; CLEAN_LOGS=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage ;;
    *) error "Unknown option: $1"; usage ;;
  esac
  shift
done

# Default to cleaning logs if no specific target given
if [[ "$CLEAN_DOCKER" == false && "$CLEAN_LOGS" == false ]]; then
  CLEAN_LOGS=true
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
run_or_dry() {
  if [[ "$DRY_RUN" == true ]]; then
    info "[dry-run] $*"
  else
    eval "$@"
  fi
}

# ── Docker cleanup ────────────────────────────────────────────────────────────
cleanup_docker() {
  info "Stopping Docker services for project '${DOCKER_PROJECT_NAME}'…"

  if ! command -v docker &>/dev/null; then
    warn "Docker not found — skipping Docker cleanup."
    return
  fi

  if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
    run_or_dry "docker compose -f '${DOCKER_COMPOSE_FILE}' -p '${DOCKER_PROJECT_NAME}' down --remove-orphans 2>/dev/null || true"
    success "Docker Compose services stopped."
  else
    warn "docker-compose.yml not found at ${DOCKER_COMPOSE_FILE} — skipping compose teardown."
  fi

  # Remove dangling images tagged for this project
  local dangling
  dangling=$(docker images -q --filter "label=project=${DOCKER_PROJECT_NAME}" 2>/dev/null || true)
  if [[ -n "$dangling" ]]; then
    run_or_dry "docker rmi $dangling 2>/dev/null || true"
    success "Removed project-tagged Docker images."
  fi
}

# ── Log / tmp cleanup ─────────────────────────────────────────────────────────
cleanup_logs() {
  info "Removing smoke-test log and temp files…"

  for target in "$LOG_DIR" "$TMP_DIR"; do
    if [[ -d "$target" ]]; then
      run_or_dry "rm -rf '${target}'"
      success "Removed: ${target}"
    else
      info "Directory not found (nothing to remove): ${target}"
    fi
  done

  # Also clean up any *.log files dropped in the project root during tests
  while IFS= read -r -d '' logfile; do
    run_or_dry "rm -f '${logfile}'"
    success "Removed stray log: ${logfile}"
  done < <(find "${PROJECT_ROOT}" -maxdepth 2 -name '*.smoke.log' -print0 2>/dev/null)
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  info "=== Smoke-Test Cleanup ==="
  [[ "$DRY_RUN" == true ]] && warn "Dry-run mode enabled — no changes will be made."
  echo ""

  [[ "$CLEAN_DOCKER" == true ]] && cleanup_docker
  [[ "$CLEAN_LOGS"   == true ]] && cleanup_logs

  echo ""
  success "Cleanup complete."
}

main
