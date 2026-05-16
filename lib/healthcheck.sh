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

_hc_log() { echo -e "[healthcheck] $*"; }

check_http() {
    _hc_log "Checking HTTP endpoint: ${HEALTH_URL}"
    local attempt=0
    local http_code curl_err curl_out

    while (( attempt < MAX_RETRIES )); do
        attempt=$(( attempt + 1 ))
        curl_err="$(mktemp)"

        http_code="$(curl -sSo /dev/null -w '%{http_code}' \
            --max-time 10 \
            --insecure \
            "${HEALTH_URL}" 2>"${curl_err}" || echo '000')"

        if [[ "$http_code" == "200" ]]; then
            success "Health check passed (HTTP ${http_code})"
            rm -f "${curl_err}"
            return 0
        fi

        warn "HTTP check attempt ${attempt}/${MAX_RETRIES}: got HTTP ${http_code}"

        if [[ -s "${curl_err}" ]]; then
            _hc_log "  curl error: $(cat "${curl_err}")"
        fi

        # On failure, run a verbose curl to expose the root cause
        if (( attempt == 1 )); then
            _hc_log "  --- verbose curl output ---"
            curl -v --max-time 10 --insecure "${HEALTH_URL}" \
                2>&1 | sed 's/^/  /' || true
            _hc_log "  --- end verbose curl ---"
        fi

        # Extra diagnostics on the last attempt
        if (( attempt == MAX_RETRIES )); then
            _hc_log "  Diagnosing failure after ${MAX_RETRIES} attempts:"
            _hc_log "    DNS lookup for ${DOMAIN}:"
            getent hosts "${DOMAIN}" 2>&1 | sed 's/^/    /' || \
                _hc_log "    (getent failed — DNS may be broken)"
            _hc_log "    TCP connectivity to ${DOMAIN}:443:"
            timeout 5 bash -c "echo >/dev/tcp/${DOMAIN}/443" 2>&1 && \
                _hc_log "    TCP:443 reachable" || \
                _hc_log "    TCP:443 NOT reachable"
            _hc_log "    TCP connectivity to ${DOMAIN}:80:"
            timeout 5 bash -c "echo >/dev/tcp/${DOMAIN}/80" 2>&1 && \
                _hc_log "    TCP:80 reachable" || \
                _hc_log "    TCP:80 NOT reachable"
        else
            _hc_log "  Retrying in ${RETRY_DELAY}s…"
            sleep "${RETRY_DELAY}"
        fi

        rm -f "${curl_err}"
    done

    warn "HTTP health check failed after ${MAX_RETRIES} attempts (last code: ${http_code})"
    return 1
}

check_supervisor() {
    if ! command -v supervisorctl &>/dev/null; then
        _hc_log "supervisorctl not found — skipping supervisor check"
        return 0
    fi

    _hc_log "Checking supervisor processes for group: ${APP_NAME}:"
    local status rc=0
    status="$(supervisorctl status "${APP_NAME}:" 2>&1)" || rc=$?

    if (( rc != 0 )); then
        warn "supervisorctl exited with code ${rc} — supervisor daemon may be down"
        _hc_log "  supervisorctl output:"
        echo "$status" | sed 's/^/  /'
        return 1
    fi

    if [[ -z "$status" ]]; then
        warn "No supervisor processes found for group '${APP_NAME}:'"
        _hc_log "  Full supervisor status:"
        supervisorctl status 2>&1 | sed 's/^/  /' || true
        return 1
    fi

    _hc_log "  Supervisor status:"
    echo "$status" | sed 's/^/  /'

    if echo "$status" | grep -qE 'FATAL|STOPPED|EXITED'; then
        warn "One or more supervisor processes are not running"
        return 1
    fi

    success "Supervisor processes OK"
}

check_phpfpm() {
    local svc="php${PHP_VERSION}-fpm"
    _hc_log "Checking PHP-FPM service: ${svc}"

    if ! systemctl is-active --quiet "${svc}"; then
        warn "PHP-FPM (${svc}) is not active"
        _hc_log "  systemctl status output:"
        systemctl status "${svc}" --no-pager -l 2>&1 | sed 's/^/  /' || true
        _hc_log "  Recent journal entries:"
        journalctl -u "${svc}" -n 20 --no-pager 2>&1 | sed 's/^/  /' || true
        return 1
    fi

    success "PHP-FPM (${svc}) is active"
}

run_healthcheck() {
    _hc_log "Starting health checks for ${APP_NAME} (${DOMAIN})"
    local failed=0

    check_phpfpm     || failed=1
    check_supervisor || failed=1
    check_http       || failed=1

    if (( failed )); then
        warn "Health check FAILED — one or more checks did not pass"
    else
        success "All health checks passed"
    fi

    return $failed
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && run_healthcheck
