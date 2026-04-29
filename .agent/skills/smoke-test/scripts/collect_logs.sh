#!/bin/bash
# collect_logs.sh - Collect and archive logs from all services for debugging
# Part of the deer-flow smoke-test skill

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/tmp/deer-flow-logs}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/tmp/deer-flow-archives}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="deer-flow-logs-${TIMESTAMP}.tar.gz"
DEPLOY_MODE="${DEPLOY_MODE:-local}"  # local | docker
MAX_LOG_LINES="${MAX_LOG_LINES:-1000}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}[collect_logs]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }

prepare_dirs() {
    mkdir -p "${LOG_DIR}" "${ARCHIVE_DIR}"
    log "Log collection directory: ${LOG_DIR}"
}

# ─── Local log collection ──────────────────────────────────────────────────────
collect_local_logs() {
    log "Collecting logs from local deployment..."

    # Backend logs
    local backend_log_paths=(
        "./logs/backend.log"
        "./backend/logs/app.log"
        "/tmp/deer-flow-backend.log"
    )
    for p in "${backend_log_paths[@]}"; do
        if [[ -f "$p" ]]; then
            log "Copying backend log: $p"
            tail -n "${MAX_LOG_LINES}" "$p" > "${LOG_DIR}/backend.log" 2>/dev/null || true
            break
        fi
    done

    # Frontend logs
    local frontend_log_paths=(
        "./logs/frontend.log"
        "./web/logs/app.log"
        "/tmp/deer-flow-frontend.log"
    )
    for p in "${frontend_log_paths[@]}"; do
        if [[ -f "$p" ]]; then
            log "Copying frontend log: $p"
            tail -n "${MAX_LOG_LINES}" "$p" > "${LOG_DIR}/frontend.log" 2>/dev/null || true
            break
        fi
    done

    # System journal (if available)
    if command -v journalctl &>/dev/null; then
        log "Collecting systemd journal entries for deer-flow..."
        journalctl -u deer-flow\* --no-pager -n "${MAX_LOG_LINES}" \
            > "${LOG_DIR}/journal.log" 2>/dev/null || true
    fi
}

# ─── Docker log collection ─────────────────────────────────────────────────────
collect_docker_logs() {
    log "Collecting logs from Docker deployment..."

    if ! command -v docker &>/dev/null; then
        warn "Docker not found; skipping Docker log collection."
        return 0
    fi

    local containers
    containers=$(docker ps --filter "name=deer-flow" --format '{{.Names}}' 2>/dev/null || true)

    if [[ -z "$containers" ]]; then
        warn "No running deer-flow containers found."
        # Try stopped containers too
        containers=$(docker ps -a --filter "name=deer-flow" --format '{{.Names}}' 2>/dev/null || true)
    fi

    if [[ -z "$containers" ]]; then
        warn "No deer-flow containers found at all."
        return 0
    fi

    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        local safe_name
        safe_name=$(echo "$container" | tr '/' '_')
        log "Collecting logs for container: $container"
        docker logs --tail="${MAX_LOG_LINES}" "$container" \
            > "${LOG_DIR}/${safe_name}.log" 2>&1 || \
            warn "Failed to collect logs for $container"
    done <<< "$containers"

    # Docker compose events (if available)
    if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        docker compose ps > "${LOG_DIR}/compose-status.txt" 2>/dev/null || true
    fi
}

# ─── Environment snapshot ──────────────────────────────────────────────────────
collect_env_snapshot() {
    log "Capturing environment snapshot..."
    {
        echo "=== Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
        echo "=== Hostname: $(hostname) ==="
        echo "=== OS: $(uname -a) ==="
        echo "=== Python: $(python3 --version 2>&1 || echo 'not found') ==="
        echo "=== Node: $(node --version 2>&1 || echo 'not found') ==="
        echo "=== Docker: $(docker --version 2>&1 || echo 'not found') ==="
        echo "=== Disk usage ==="
        df -h . 2>/dev/null || true
        echo "=== Memory ==="
        free -h 2>/dev/null || vm_stat 2>/dev/null || true
    } > "${LOG_DIR}/env-snapshot.txt" 2>&1
}

# ─── Archive ──────────────────────────────────────────────────────────────────
archive_logs() {
    local archive_path="${ARCHIVE_DIR}/${ARCHIVE_NAME}"
    log "Creating archive: ${archive_path}"
    tar -czf "${archive_path}" -C "$(dirname "${LOG_DIR}")" "$(basename "${LOG_DIR}")" 2>/dev/null
    ok "Logs archived to: ${archive_path}"
    echo "${archive_path}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    log "Starting log collection (mode: ${DEPLOY_MODE})"
    prepare_dirs
    collect_env_snapshot

    case "${DEPLOY_MODE}" in
        docker) collect_docker_logs ;;
        local)  collect_local_logs  ;;
        *)
            warn "Unknown DEPLOY_MODE '${DEPLOY_MODE}'; collecting both."
            collect_local_logs
            collect_docker_logs
            ;;
    esac

    local archive
    archive=$(archive_logs)
    ok "Log collection complete. Archive: ${archive}"
}

main "$@"
