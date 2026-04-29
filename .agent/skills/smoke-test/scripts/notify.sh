#!/bin/bash
# notify.sh - Send notifications about smoke test results
# Supports Slack webhooks, email (via sendmail/mailx), and file-based alerts

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/tmp/deer-flow-smoke-test.log}"
REPORT_FILE="${REPORT_FILE:-/tmp/deer-flow-report.txt}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-all}"  # slack | email | file | all
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
APP_ENV="${APP_ENV:-unknown}"
BUILD_VERSION="${BUILD_VERSION:-unknown}"

# Colour codes (used only when writing to terminal)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
info()    { log "${GREEN}[INFO]${NC}  $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
error()   { log "${RED}[ERROR]${NC} $*"; }

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Build a short summary line from the report file (or fall back to a default)
build_summary() {
    local status="$1"
    if [[ -f "${REPORT_FILE}" ]]; then
        # Pull the SUMMARY line written by report_results.sh if present
        grep -m1 'SUMMARY:' "${REPORT_FILE}" 2>/dev/null \
            | sed 's/.*SUMMARY:[[:space:]]*//' \
            || echo "Smoke test ${status} — see attached report."
    else
        echo "Smoke test ${status} — no report file found."
    fi
}

# ─── Slack notification ───────────────────────────────────────────────────────
send_slack() {
    local status="$1"   # PASSED | FAILED | WARNING
    local summary
    summary="$(build_summary "${status}")"

    if [[ -z "${SLACK_WEBHOOK_URL}" ]]; then
        warn "SLACK_WEBHOOK_URL is not set — skipping Slack notification."
        return 0
    fi

    local emoji color
    case "${status}" in
        PASSED)  emoji=":white_check_mark:"; color="good"    ;;
        WARNING) emoji=":warning:";          color="warning" ;;
        *)       emoji=":x:";               color="danger"  ;;
    esac

    local payload
    payload=$(cat <<EOF
{
  "attachments": [{
    "color": "${color}",
    "title": "${emoji} DeerFlow Smoke Test — ${status}",
    "text": "${summary}",
    "fields": [
      {"title": "Environment", "value": "${APP_ENV}",      "short": true},
      {"title": "Version",     "value": "${BUILD_VERSION}", "short": true}
    ],
    "footer": "deer-flow CI",
    "ts": $(date +%s)
  }]
}
EOF
)

    if curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H 'Content-Type: application/json' \
            --data "${payload}" \
            "${SLACK_WEBHOOK_URL}" | grep -q '^2'; then
        info "Slack notification sent (${status})."
    else
        warn "Failed to send Slack notification."
    fi
}

# ─── Email notification ───────────────────────────────────────────────────────
send_email() {
    local status="$1"
    local summary
    summary="$(build_summary "${status}")"

    if [[ -z "${NOTIFY_EMAIL}" ]]; then
        warn "NOTIFY_EMAIL is not set — skipping email notification."
        return 0
    fi

    local subject="[DeerFlow] Smoke Test ${status} — env:${APP_ENV} ver:${BUILD_VERSION}"
    local body
    body=$(printf '%s\n\n%s\n' "${summary}" "$(cat "${REPORT_FILE}" 2>/dev/null || echo '(no report)')")

    if command -v mailx &>/dev/null; then
        echo "${body}" | mailx -s "${subject}" "${NOTIFY_EMAIL}" \
            && info "Email sent to ${NOTIFY_EMAIL}." \
            || warn "mailx failed — email not delivered."
    elif command -v sendmail &>/dev/null; then
        { printf 'To: %s\nSubject: %s\n\n%s\n' "${NOTIFY_EMAIL}" "${subject}" "${body}"; } \
            | sendmail -t \
            && info "Email queued via sendmail." \
            || warn "sendmail failed — email not delivered."
    else
        warn "No mail client found (mailx/sendmail) — skipping email notification."
    fi
}

# ─── File-based alert ─────────────────────────────────────────────────────────
send_file_alert() {
    local status="$1"
    local alert_file="/tmp/deer-flow-alert-${status,,}-$(date +%Y%m%d%H%M%S).txt"

    {
        echo "DeerFlow Smoke Test Alert"
        echo "========================="
        echo "Status:      ${status}"
        echo "Environment: ${APP_ENV}"
        echo "Version:     ${BUILD_VERSION}"
        echo "Timestamp:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo ""
        echo "Summary: $(build_summary "${status}")"
        echo ""
        echo "--- Full Report ---"
        cat "${REPORT_FILE}" 2>/dev/null || echo "(report not available)"
    } > "${alert_file}"

    info "File alert written to ${alert_file}."
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────
main() {
    local status="${1:-UNKNOWN}"

    info "Sending notifications for status: ${status} (channel: ${NOTIFY_CHANNEL})"

    case "${NOTIFY_CHANNEL}" in
        slack)  send_slack "${status}" ;;
        email)  send_email "${status}" ;;
        file)   send_file_alert "${status}" ;;
        all)
            send_slack "${status}"
            send_email "${status}"
            send_file_alert "${status}"
            ;;
        *)
            warn "Unknown NOTIFY_CHANNEL '${NOTIFY_CHANNEL}' — defaulting to file alert."
            send_file_alert "${status}"
            ;;
    esac

    info "Notification dispatch complete."
}

main "$@"
