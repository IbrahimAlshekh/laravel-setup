#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Repeatable application deployment
#
# Usage (manual):
#   sudo bash deploy.sh           # run as root → drops to APP_USER internally
#   sudo -u <APP_USER> bash deploy.sh  # or run directly as the app user
#
# Usage (initial, called from setup.sh):
#   bash deploy.sh --initial      # skips pre-deploy backup on first run
#
# Triggered automatically when DEPLOY_ON_PUSH=true (via webhook listener).
#
# AUTO_ROLLBACK=true → restores last snapshot automatically on failure.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_deploy_env

# shellcheck source=lib/secrets.sh
source "${SCRIPT_DIR}/lib/secrets.sh"
load_secrets

# ── Argument parsing ──────────────────────────────────────────────────────────
INITIAL_DEPLOY=false
AUTO_ROLLBACK="${AUTO_ROLLBACK:-false}"

for arg in "$@"; do
    [[ "$arg" == "--initial" ]] && INITIAL_DEPLOY=true
done

# ── Privilege handling ────────────────────────────────────────────────────────
# If invoked as root, re-exec as APP_USER (non-root owns the code).
# setup.sh calls this explicitly as APP_USER, but manual sudo goes through root.
if [[ $EUID -eq 0 ]]; then
    exec sudo -u "${APP_USER}" \
        env AUTO_ROLLBACK="${AUTO_ROLLBACK}" \
            DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-${SCRIPT_DIR}/.env.deploy}" \
        bash "${BASH_SOURCE[0]}" "$@"
fi

# From here we run as APP_USER.
[[ "$(id -un)" == "${APP_USER}" ]] || \
    error "deploy.sh must run as ${APP_USER} (got $(id -un))"

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ -d "${APP_DIR}/.git" ]] || error "Not a git repository: ${APP_DIR}. Run setup.sh first."
[[ -f "${APP_DIR}/.env" ]] || error ".env not found in ${APP_DIR}. Run setup.sh first."

cd "${APP_DIR}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Deploy log ────────────────────────────────────────────────────────────────
mkdir -p "${APP_DIR}/storage/logs"
exec > >(tee -a "${DEPLOY_LOG}") 2>&1
# (all output from here goes to both stdout and the deploy log)

section "Deploy — $(date '+%Y-%m-%d %H:%M:%S')  (user: $(id -un))"

# ── 1. Pre-deploy backup ──────────────────────────────────────────────────────
if [[ "${INITIAL_DEPLOY}" == "false" ]]; then
    section "Pre-deploy backup"
    # shellcheck source=lib/backup.sh
    source "${SCRIPT_DIR}/lib/backup.sh"
    run_backup
fi

# ── 2. Maintenance mode ON ────────────────────────────────────────────────────
section "Maintenance mode ON"
MAINTENANCE_SECRET="$(openssl rand -hex 16)"
php artisan down \
    --secret="${MAINTENANCE_SECRET}" \
    --render="errors::503" \
    --retry=60 2>/dev/null || true
info "Maintenance bypass secret: ${MAINTENANCE_SECRET}"

# ── 3. Failure trap ───────────────────────────────────────────────────────────
# On any error: lift maintenance mode; optionally restore last backup.
_deploy_failed() {
    local exit_code=$?
    warn "Deployment failed (exit ${exit_code}) — lifting maintenance mode"
    php artisan up 2>/dev/null || true

    if [[ "${AUTO_ROLLBACK}" == "true" ]]; then
        warn "AUTO_ROLLBACK=true — attempting to restore last snapshot"
        sudo bash "${SCRIPT_DIR}/lib/restore.sh" --last 2>/dev/null || \
            warn "Automatic restore failed — manual intervention required"
    else
        warn "Set AUTO_ROLLBACK=true in .env.deploy to enable automatic restore."
        warn "Manual restore: sudo bash ${SCRIPT_DIR}/lib/restore.sh --last"
    fi

    info "Deploy log: ${DEPLOY_LOG}"
}
trap _deploy_failed ERR

# ── 4. Pull latest code ───────────────────────────────────────────────────────
section "Git pull (${REPO_BRANCH})"
git fetch --prune origin "${REPO_BRANCH}"
git reset --hard "origin/${REPO_BRANCH}"
COMMIT="$(git rev-parse --short HEAD)"
info "Deployed commit: $(git log -1 --oneline)"

# ── 5. Composer ───────────────────────────────────────────────────────────────
section "Composer install"
composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction \
    --no-progress \
    --prefer-dist
success "Composer dependencies updated"

# ── 6. Node.js assets ─────────────────────────────────────────────────────────
# Only build if a pnpm lockfile (or package.json) exists.
if [[ -f "pnpm-lock.yaml" ]]; then
    section "pnpm build"
    pnpm install --frozen-lockfile
    pnpm run build
    success "Assets compiled"
elif [[ -f "package-lock.json" ]]; then
    section "npm build"
    npm ci --omit=dev
    npm run build
    success "Assets compiled (npm)"
fi

# ── 7. Artisan: clear old caches first ────────────────────────────────────────
section "Clear caches"
php artisan optimize:clear

# ── 8. Migrations ─────────────────────────────────────────────────────────────
section "Database migrations"
php artisan migrate --force
success "Migrations complete"

# ── 9. Storage symlink ────────────────────────────────────────────────────────
php artisan storage:link --force 2>/dev/null || true

# ── 10. File permissions ──────────────────────────────────────────────────────
section "Permissions"
# Only fix the writable directories — not the entire repo (avoids slow find + touching .git).
chmod -R ug+rw,o-w "${APP_DIR}/storage"
chmod -R ug+rw,o-w "${APP_DIR}/bootstrap/cache"
find "${APP_DIR}/storage" -type d -exec chmod ug+rwx,o-rx {} \;
find "${APP_DIR}/bootstrap/cache" -type d -exec chmod ug+rwx,o-rx {} \;
success "Permissions set"

# ── 11. Rebuild caches ────────────────────────────────────────────────────────
section "Optimise"
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan event:cache
success "Laravel caches rebuilt"

# ── 12. Restart services ──────────────────────────────────────────────────────
section "Service restart"
# Full restart of PHP-FPM is required: OPcache validate_timestamps=0 means
# reload alone won't pick up new bytecode.
sudo /bin/systemctl restart "php${PHP_VERSION}-fpm"
sudo /usr/bin/supervisorctl restart "${APP_NAME}:*" 2>/dev/null || true
success "Services restarted"

# ── 13. Maintenance mode OFF ──────────────────────────────────────────────────
trap - ERR   # remove failure trap before calling `up`
php artisan up
success "Application is live"

# ── 14. Health check ──────────────────────────────────────────────────────────
section "Health check"
# shellcheck source=lib/healthcheck.sh
source "${SCRIPT_DIR}/lib/healthcheck.sh"
run_healthcheck

# ── Summary ───────────────────────────────────────────────────────────────────
section "Deployment complete"
echo -e "${GREEN}${BOLD}"
echo "  Commit : $(git log -1 --oneline)"
echo "  URL    : https://${DOMAIN}"
echo "  Log    : ${DEPLOY_LOG}"
echo -e "${NC}"
info "Backups in: ${BACKUP_DIR}   (run 'sudo bash lib/restore.sh --list' to view)"
