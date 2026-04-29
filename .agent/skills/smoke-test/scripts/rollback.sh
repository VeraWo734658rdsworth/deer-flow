#!/bin/bash
# rollback.sh - Rollback deployment to previous state
# Part of the deer-flow smoke-test skill
#
# Usage: ./rollback.sh [--mode docker|local] [--backup-dir <path>]

set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
DEFAULT_BACKUP_DIR="${PROJECT_ROOT}/.agent/backups"
LOG_FILE="${PROJECT_ROOT}/logs/rollback.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ─── Defaults ────────────────────────────────────────────────────────────────
MODE="local"
BACKUP_DIR="${DEFAULT_BACKUP_DIR}"

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo -e "[${TIMESTAMP}] $*" | tee -a "${LOG_FILE}"; }
info() { echo -e "${CYAN}[INFO]${NC}  $*" | tee -a "${LOG_FILE}"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "${LOG_FILE}"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "${LOG_FILE}"; }

usage() {
  echo "Usage: $0 [--mode docker|local] [--backup-dir <path>]"
  echo
  echo "Options:"
  echo "  --mode        Deployment mode: 'docker' or 'local' (default: local)"
  echo "  --backup-dir  Directory containing backup snapshots (default: ${DEFAULT_BACKUP_DIR})"
  echo "  -h, --help    Show this help message"
  exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)       MODE="$2";       shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *) error "Unknown argument: $1"; usage ;;
  esac
done

mkdir -p "$(dirname "${LOG_FILE}")"
log "=== Rollback started (mode=${MODE}) ==="

# ─── Locate latest backup ─────────────────────────────────────────────────────
find_latest_backup() {
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    error "Backup directory not found: ${BACKUP_DIR}"
    exit 1
  fi

  LATEST=$(find "${BACKUP_DIR}" -maxdepth 1 -type d -name 'snapshot_*' \
    | sort -r | head -n1)

  if [[ -z "${LATEST}" ]]; then
    error "No backup snapshots found in ${BACKUP_DIR}"
    exit 1
  fi

  info "Found latest backup: ${LATEST}"
  echo "${LATEST}"
}

# ─── Docker rollback ──────────────────────────────────────────────────────────
rollback_docker() {
  local backup_path="$1"
  local compose_backup="${backup_path}/docker-compose.yml"

  if [[ ! -f "${compose_backup}" ]]; then
    error "docker-compose.yml not found in backup: ${backup_path}"
    exit 1
  fi

  info "Stopping current containers..."
  docker compose -f "${PROJECT_ROOT}/docker-compose.yml" down --remove-orphans 2>&1 \
    | tee -a "${LOG_FILE}" || warn "Some containers may not have been running."

  info "Restoring docker-compose.yml from backup..."
  cp "${compose_backup}" "${PROJECT_ROOT}/docker-compose.yml"

  # Restore .env if backed up
  if [[ -f "${backup_path}/.env" ]]; then
    info "Restoring .env from backup..."
    cp "${backup_path}/.env" "${PROJECT_ROOT}/.env"
  fi

  info "Pulling images specified in restored compose file..."
  docker compose -f "${PROJECT_ROOT}/docker-compose.yml" pull 2>&1 \
    | tee -a "${LOG_FILE}"

  info "Starting containers from restored configuration..."
  docker compose -f "${PROJECT_ROOT}/docker-compose.yml" up -d 2>&1 \
    | tee -a "${LOG_FILE}"

  ok "Docker rollback complete."
}

# ─── Local rollback ───────────────────────────────────────────────────────────
rollback_local() {
  local backup_path="$1"

  # Restore .env
  if [[ -f "${backup_path}/.env" ]]; then
    info "Restoring .env from backup..."
    cp "${backup_path}/.env" "${PROJECT_ROOT}/.env"
  else
    warn ".env not found in backup; skipping environment restore."
  fi

  # Restore conf.yaml if present
  if [[ -f "${backup_path}/conf.yaml" ]]; then
    info "Restoring conf.yaml from backup..."
    cp "${backup_path}/conf.yaml" "${PROJECT_ROOT}/conf.yaml"
  fi

  # Restart backend service if a PID file exists
  PID_FILE="${PROJECT_ROOT}/.agent/run/backend.pid"
  if [[ -f "${PID_FILE}" ]]; then
    OLD_PID=$(cat "${PID_FILE}")
    info "Stopping existing backend process (PID ${OLD_PID})..."
    kill "${OLD_PID}" 2>/dev/null || warn "Process ${OLD_PID} was not running."
    rm -f "${PID_FILE}"
  fi

  info "Reinstalling Python dependencies from backup requirements..."
  if [[ -f "${backup_path}/requirements.txt" ]]; then
    pip install -q -r "${backup_path}/requirements.txt" 2>&1 | tee -a "${LOG_FILE}"
  else
    warn "requirements.txt not found in backup; skipping pip install."
  fi

  ok "Local rollback complete. Please restart the application manually."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  BACKUP_PATH=$(find_latest_backup)

  case "${MODE}" in
    docker) rollback_docker "${BACKUP_PATH}" ;;
    local)  rollback_local  "${BACKUP_PATH}" ;;
    *)
      error "Invalid mode '${MODE}'. Choose 'docker' or 'local'."
      exit 1
      ;;
  esac

  log "=== Rollback finished ==="
}

main
