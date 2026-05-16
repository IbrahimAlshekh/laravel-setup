#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Repeatable application deployment
#
# Usage:
#   sudo bash deploy.sh           # must run as root
#   sudo bash deploy.sh --initial # skips pre-deploy backup on first run
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
require_root
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
# Root runs git on a directory owned by APP_USER — mark it safe to suppress
# the "dubious ownership" error introduced in git 2.35.2.
git config --global --add safe.directory "${APP_DIR}" 2>/dev/null || true
git fetch --prune origin "${REPO_BRANCH}"
git reset --hard "origin/${REPO_BRANCH}"
COMMIT="$(git rev-parse --short HEAD)"
info "Deployed commit: $(git log -1 --oneline)"

# Verify this is actually a Laravel application before going any further.
[[ -f "composer.json" ]] || \
    error "No composer.json found in ${APP_DIR}.\nCheck REPO_URL in .env.deploy — it must point to your Laravel application repo."
[[ -f "artisan" ]] || \
    error "No artisan script found in ${APP_DIR}.\nThis does not appear to be a Laravel application."

# ── 5. Composer ───────────────────────────────────────────────────────────────
section "Composer install"
export COMPOSER_ALLOW_SUPERUSER=1
export COMPOSER_NO_INTERACTION=1
export COMPOSER_HOME=/root/.composer
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
    # --frozen-lockfile enforces integrity checksums, so allowing build scripts
    # here matches the trust level of `npm ci` / `yarn install --frozen-lockfile`.
    pnpm install --frozen-lockfile --config.dangerouslyAllowAllBuilds=true
    pnpm run build
    chown -R "${APP_USER}:www-data" "${APP_DIR}/public/build" 2>/dev/null || true
    success "Assets compiled"
elif [[ -f "package-lock.json" ]]; then
    section "npm build"
    npm ci --omit=dev
    npm run build
    chown -R "${APP_USER}:www-data" "${APP_DIR}/public/build" 2>/dev/null || true
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

# ── 10. File permissions & ownership ─────────────────────────────────────────
section "Permissions"
# Hand all files to APP_USER:www-data so the PHP-FPM pool (running as APP_USER)
# owns the code. Root deployed the files; now transfer ownership for isolation.
chown -R "${APP_USER}:www-data" "${APP_DIR}"
# Directories: 755 — owner rwx, group rx, others rx
find "${APP_DIR}" -not -path "${APP_DIR}/.git/*" -type d -exec chmod 755 {} \;
# Files: 644
find "${APP_DIR}" -not -path "${APP_DIR}/.git/*" -type f -exec chmod 644 {} \;
# Writable directories: 775 — APP_USER and www-data (FPM) can write
chmod -R 775 "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
# .env must not be world-readable
chmod 640 "${APP_DIR}/.env" 2>/dev/null || true
success "Ownership → ${APP_USER}:www-data, permissions set"

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
systemctl restart "php${PHP_VERSION}-fpm"
supervisorctl restart "${APP_NAME}:*" 2>/dev/null || true
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
