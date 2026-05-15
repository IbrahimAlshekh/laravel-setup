#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore a backup snapshot (DB + storage + git checkout)
#
# Usage:
#   sudo bash lib/restore.sh --last              # restore most recent snapshot
#   sudo bash lib/restore.sh --timestamp 20240115_023001
#   sudo bash lib/restore.sh --list              # list available snapshots
#
# The restore always puts the app into maintenance mode first and lifts it
# after the restore (or on failure).  It does NOT run migrations in reverse —
# restoring a DB dump is the rollback mechanism for schema changes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_deploy_env
# shellcheck source=lib/secrets.sh
source "${SCRIPT_DIR}/lib/secrets.sh"
load_secrets

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE=""
TIMESTAMP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --last)      MODE="last" ;;
        --list)      MODE="list" ;;
        --timestamp) MODE="ts"; shift; TIMESTAMP="$1" ;;
        *) error "Unknown argument: $1" ;;
    esac
    shift
done

[[ -z "$MODE" ]] && error "Usage: $0 --last | --list | --timestamp YYYYMMDD_HHMMSS"

# ── List ──────────────────────────────────────────────────────────────────────
list_snapshots() {
    section "Available snapshots in ${BACKUP_DIR}"
    ls -t "${BACKUP_DIR}"/git_*.ref 2>/dev/null | while read -r ref_file; do
        local ts commit
        ts="$(basename "$ref_file" .ref | sed 's/^git_//')"
        commit="$(cat "$ref_file" 2>/dev/null || echo '?')"
        local db_file storage_file
        db_file="$(ls "${BACKUP_DIR}/db_${ts}."* 2>/dev/null | head -1 || echo '—')"
        storage_file="${BACKUP_DIR}/storage_${ts}.tar.gz"
        [[ -f "$storage_file" ]] || storage_file="—"
        printf "  %s  commit=%.8s  db=%s\n" "$ts" "$commit" "$(basename "$db_file")"
    done
}

# ── Resolve timestamp ─────────────────────────────────────────────────────────
resolve_timestamp() {
    if [[ "$MODE" == "last" ]]; then
        TIMESTAMP="$(ls -t "${BACKUP_DIR}"/git_*.ref 2>/dev/null | head -1 | xargs basename 2>/dev/null | sed 's/^git_//;s/\.ref$//')"
        [[ -n "$TIMESTAMP" ]] || error "No snapshots found in ${BACKUP_DIR}"
    fi
    [[ -f "${BACKUP_DIR}/git_${TIMESTAMP}.ref" ]] || error "Snapshot not found: ${TIMESTAMP}"
}

# ── Restore ───────────────────────────────────────────────────────────────────
do_restore() {
    section "Restoring snapshot ${TIMESTAMP}"

    require_root

    # Maintenance mode on
    sudo -u "${APP_USER}" php "${APP_DIR}/artisan" down \
        --render="errors::503" 2>/dev/null || true

    # Lift maintenance mode on exit (success or failure)
    trap 'sudo -u "${APP_USER}" php "${APP_DIR}/artisan" up 2>/dev/null || true' EXIT

    # ── Code rollback ─────────────────────────────────────────────────────────
    local target_commit
    target_commit="$(cat "${BACKUP_DIR}/git_${TIMESTAMP}.ref")"
    info "Checking out commit ${target_commit}"
    sudo -u "${APP_USER}" git -C "${APP_DIR}" checkout "${target_commit}" -- .
    success "Code restored to ${target_commit}"

    # ── DB restore ────────────────────────────────────────────────────────────
    local db_sql="${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"
    local db_sqlite="${BACKUP_DIR}/db_${TIMESTAMP}.sqlite.gz"
    local db_name db_user db_pass db_host db_port
    db_host="$(  grep -E '^DB_HOST='     "${APP_DIR}/.env" | cut -d= -f2 | tr -d '"' || echo '127.0.0.1')"
    db_port="$(  grep -E '^DB_PORT='     "${APP_DIR}/.env" | cut -d= -f2 | tr -d '"' || echo '3306')"
    db_name="$(  grep -E '^DB_DATABASE=' "${APP_DIR}/.env" | cut -d= -f2 | tr -d '"' || echo "${APP_NAME}")"
    db_user="$(  grep -E '^DB_USERNAME=' "${APP_DIR}/.env" | cut -d= -f2 | tr -d '"' || echo "${APP_NAME}")"
    db_pass="$(  grep -E '^DB_PASSWORD=' "${APP_DIR}/.env" | cut -d= -f2 | tr -d '"' || echo "${DB_PASS}")"

    if [[ -f "$db_sql" ]]; then
        info "Restoring MySQL database from ${db_sql}"
        zcat "${db_sql}" | mysql -h"${db_host}" -P"${db_port}" -u"${db_user}" -p"${db_pass}" "${db_name}"
        success "Database restored"
    elif [[ -f "$db_sqlite" ]]; then
        local sqlite_path
        sqlite_path="$(grep -E '^DB_DATABASE=' "${APP_DIR}/.env" | cut -d= -f2 | tr -d '"' || echo '')"
        [[ "${sqlite_path}" != /* ]] && sqlite_path="${APP_DIR}/${sqlite_path}"
        [[ -f "${sqlite_path}" ]] || sqlite_path="${APP_DIR}/database/database.sqlite"
        info "Restoring SQLite from ${db_sqlite}"
        zcat "${db_sqlite}" > "${sqlite_path}"
        chown "${APP_USER}:www-data" "${sqlite_path}"
        success "SQLite restored"
    else
        warn "No DB backup found for timestamp ${TIMESTAMP}, skipping DB restore"
    fi

    # ── Storage restore ───────────────────────────────────────────────────────
    local storage_backup="${BACKUP_DIR}/storage_${TIMESTAMP}.tar.gz"
    if [[ -f "$storage_backup" ]]; then
        info "Restoring storage from ${storage_backup}"
        tar -xzf "${storage_backup}" -C "${APP_DIR}"
        chown -R "${APP_USER}:www-data" "${APP_DIR}/storage/app"
        success "Storage restored"
    else
        warn "No storage backup for timestamp ${TIMESTAMP}, skipping storage restore"
    fi

    # ── Re-cache ──────────────────────────────────────────────────────────────
    sudo -u "${APP_USER}" php "${APP_DIR}/artisan" optimize:clear
    sudo -u "${APP_USER}" php "${APP_DIR}/artisan" config:cache
    sudo -u "${APP_USER}" php "${APP_DIR}/artisan" route:cache
    sudo -u "${APP_USER}" php "${APP_DIR}/artisan" view:cache

    systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
    supervisorctl restart "${APP_NAME}:*" 2>/dev/null || true

    # Trap will call artisan up on exit.
    trap - EXIT
    sudo -u "${APP_USER}" php "${APP_DIR}/artisan" up
    success "Restore complete — application is live at snapshot ${TIMESTAMP}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "list" ]]; then
    list_snapshots
else
    resolve_timestamp
    do_restore
fi
