#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — Post-deploy health verification
#
# Checks:
#   1. HTTP 200 from https://$DOMAIN/up  (Laravel 11 built-in health endpoint)
#   2. Supervisor processes are running
#   3. PHP-FPM is active
#
# Exit 0 = healthy, Exit 1 = unhealthy (deploy.sh will trigger rollback path)
# =============================================================================
set -euo pipefail

# Allow standalone sourcing.
: "${DOMAIN:?DOMAIN is required}"
: "${APP_NAME:?APP_NAME is required}"
: "${PHP_VERSION:?PHP_VERSION is required}"

HEALTH_URL="https://${DOMAIN}/up"
MAX_RETRIES=6
RETRY_DELAY=5

check_http() {
    local attempt=0
    local http_code
    while (( attempt < MAX_RETRIES )); do
        http_code="$(curl -sSo /dev/null -w '%{http_code}' \
            --max-time 10 \
            --insecure \
            "${HEALTH_URL}" 2>/dev/null || echo '000')"
        if [[ "$http_code" == "200" ]]; then
            success "Health check passed (HTTP ${http_code})"
            return 0
        fi
        attempt=$(( attempt + 1 ))
        warn "Health check attempt ${attempt}/${MAX_RETRIES}: HTTP ${http_code} — retrying in ${RETRY_DELAY}s"
        sleep "${RETRY_DELAY}"
    done
    error "Health check failed after ${MAX_RETRIES} attempts (last code: ${http_code})"
}

check_supervisor() {
    if command -v supervisorctl &>/dev/null; then
        local status
        status="$(supervisorctl status "${APP_NAME}:" 2>/dev/null || true)"
        if echo "$status" | grep -qE 'FATAL|STOPPED|EXITED'; then
            warn "Some Supervisor processes are not running:"
            echo "$status"
            return 1
        fi
        success "Supervisor processes OK"
    fi
}

check_phpfpm() {
    systemctl is-active --quiet "php${PHP_VERSION}-fpm" && \
        success "PHP-FPM is active" || \
        { warn "PHP-FPM is not active"; return 1; }
}

run_healthcheck() {
    local failed=0
    check_phpfpm     || failed=1
    check_supervisor || failed=1
    check_http       || failed=1
    return $failed
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && run_healthcheck
