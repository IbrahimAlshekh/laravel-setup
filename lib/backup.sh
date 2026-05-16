#!/usr/bin/env bash
# =============================================================================
# backup.sh — Create a timestamped backup snapshot (DB + storage + git ref)
#             and rotate old snapshots to keep at most $KEEP_BACKUPS sets.
#
# Called by:
#   • deploy.sh  before every deployment  (pre-deploy snapshot)
#   • daily cron job at 02:30             (scheduled snapshot)
#
# Required env (inherited from caller):
#   APP_DIR, APP_NAME, BACKUP_DIR, KEEP_BACKUPS, SECRETS_FILE
#   DB_PASS, DB_ROOT_PASS (loaded from secrets when called standalone)
#
# Usage (standalone): sudo bash lib/backup.sh
# =============================================================================
set -euo pipefail

# Allow standalone invocation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/lib/common.sh"
    load_deploy_env
    # shellcheck source=lib/secrets.sh
    source "${SCRIPT_DIR}/lib/secrets.sh"
    load_secrets
fi

# ── Helpers (may already be sourced) ─────────────────────────────────────────
declare -f info    > /dev/null || info()    { echo "$*"; }
declare -f success > /dev/null || success() { echo "$*"; }
declare -f warn    > /dev/null || warn()    { echo "$*" >&2; }
declare -f error   > /dev/null || { echo "error function must be defined" >&2; exit 1; }

# ── Core ──────────────────────────────────────────────────────────────────────
run_backup() {
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"
    chown root:root "${BACKUP_DIR}"

    # ── Database ──────────────────────────────────────────────────────────────
    local db_conn db_host db_port db_name db_user db_pass
    db_conn="$(  grep -E '^DB_CONNECTION=' "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'mysql')"
    db_host="$(  grep -E '^DB_HOST='       "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo '127.0.0.1')"
    db_port="$(  grep -E '^DB_PORT='       "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo '3306')"
    db_name="$(  grep -E '^DB_DATABASE='   "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "${APP_NAME}")"
    db_user="$(  grep -E '^DB_USERNAME='   "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "${APP_NAME}")"
    db_pass="$(  grep -E '^DB_PASSWORD='   "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "${DB_PASS:-}")"

    case "$db_conn" in
        mysql|mariadb)
            local db_backup="${BACKUP_DIR}/db_${timestamp}.sql.gz"
            local tmp_cnf
            tmp_cnf="$(mktemp)"
            chmod 600 "${tmp_cnf}"
            printf '[mysqldump]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' \
                "${db_host}" "${db_port}" "${db_user}" "${db_pass}" > "${tmp_cnf}"
            mysqldump \
                --defaults-extra-file="${tmp_cnf}" \
                --connect-timeout=10 \
                --single-transaction \
                --quick \
                --lock-tables=false \
                --set-gtid-purged=OFF \
                "${db_name}" | gzip -9 > "${db_backup}"
            rm -f "${tmp_cnf}"
            chmod 600 "${db_backup}"
            success "DB backup → ${db_backup}"
            ;;
        sqlite)
            local sqlite_path
            # Resolve path: absolute if it starts with /, else relative to APP_DIR.
            sqlite_path="$db_name"
            [[ "${sqlite_path}" != /* ]] && sqlite_path="${APP_DIR}/${sqlite_path}"
            [[ -f "${sqlite_path}" ]] || sqlite_path="${APP_DIR}/database/database.sqlite"
            if [[ -f "${sqlite_path}" ]]; then
                local sqlite_backup="${BACKUP_DIR}/db_${timestamp}.sqlite.gz"
                gzip -9 -c "${sqlite_path}" > "${sqlite_backup}"
                chmod 600 "${sqlite_backup}"
                success "SQLite backup → ${sqlite_backup}"
            else
                warn "SQLite file not found, skipping DB backup"
            fi
            ;;
        *)
            warn "Unsupported DB_CONNECTION=${db_conn}, skipping DB backup"
            ;;
    esac

    # ── Storage (user-uploaded files) ─────────────────────────────────────────
    if [[ -d "${APP_DIR}/storage/app" ]]; then
        local storage_backup="${BACKUP_DIR}/storage_${timestamp}.tar.gz"
        tar -czf "${storage_backup}" \
            --exclude="${APP_DIR}/storage/logs" \
            --exclude="${APP_DIR}/storage/framework" \
            -C "${APP_DIR}" \
            storage/app 2>/dev/null
        chmod 600 "${storage_backup}"
        success "Storage backup → ${storage_backup}"
    fi

    # ── Git ref (for code rollback) ────────────────────────────────────────────
    if [[ -d "${APP_DIR}/.git" ]]; then
        local ref_file="${BACKUP_DIR}/git_${timestamp}.ref"
        git -C "${APP_DIR}" rev-parse HEAD > "${ref_file}"
        chmod 600 "${ref_file}"
    fi

    # ── Rotate old backups ────────────────────────────────────────────────────
    _rotate "${BACKUP_DIR}" "db_*.sql.gz"
    _rotate "${BACKUP_DIR}" "db_*.sqlite.gz"
    _rotate "${BACKUP_DIR}" "storage_*.tar.gz"
    _rotate "${BACKUP_DIR}" "git_*.ref"

    success "Backup complete (keeping last ${KEEP_BACKUPS})"
}

# Keep at most KEEP_BACKUPS files matching a glob, deleting the oldest.
_rotate() {
    local dir="$1" glob="$2"
    # Use nullglob so the loop is a no-op if there are no matches.
    local files
    mapfile -t files < <(ls -t "${dir}/"${glob} 2>/dev/null || true)
    local count="${#files[@]}"
    local keep="${KEEP_BACKUPS:-7}"
    if (( count > keep )); then
        local to_delete=("${files[@]:${keep}}")
        rm -f "${to_delete[@]}"
    fi
}

# Run if invoked directly (not sourced).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && run_backup
