#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-time server provisioning for a Laravel application
#
# Usage : sudo bash setup.sh
# Prereq: copy .env.deploy.example → .env.deploy and fill in the 9 values.
#
# Idempotent — safe to re-run on an already-provisioned server.
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

echo ""
section "Laravel Server Setup — ${DOMAIN}"
info "App directory : ${APP_DIR}"
info "App user      : ${APP_USER}"
info "PHP version   : ${PHP_VERSION}"
info "Deploy on push: ${DEPLOY_ON_PUSH}"
echo ""
warn "This will install and configure the full production stack."
warn "Ensure your SSH public key is authorised on this server before continuing"
warn "— password authentication will be disabled at the end of this script."
echo ""
read -rp "Press Enter to begin, or Ctrl-C to cancel..."

# ── 1. Secrets ────────────────────────────────────────────────────────────────
section "Secrets"
init_secrets
load_secrets

# ── 1b. App user ───────────────────────────────────────────────────────────────
# Created here — before PHP-FPM is started — because the pool config references
# this user by name. FPM fails with EX_CONFIG if the user doesn't exist yet.
section "App user — ${APP_USER}"
if ! getent passwd "${APP_USER}" &>/dev/null; then
    useradd \
        --system \
        --shell /bin/bash \
        --home-dir "${APP_DIR}" \
        --no-create-home \
        --groups www-data \
        "${APP_USER}"
fi
usermod -aG www-data "${APP_USER}" 2>/dev/null || true
success "User ${APP_USER} ready"

# ── 2. System packages ────────────────────────────────────────────────────────
section "System update & base packages"
export DEBIAN_FRONTEND=noninteractive

# Block apt post-install service auto-starts for the entire package-install
# phase. On re-runs, apt-get upgrade may upgrade php-fpm while www.conf is
# already disabled (no valid pool) — the automatic invoke-rc.d restart inside
# the post-install hook then fails with exit code 78 (EX_CONFIG) and aborts
# the entire apt-get command. We remove this file after all packages are
# installed and start every service ourselves.
_remove_policy_rc() { rm -f /usr/sbin/policy-rc.d; }
cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod +x /usr/sbin/policy-rc.d
# Safety net: always clean up on exit, even if the script fails mid-way.
trap '_remove_policy_rc' EXIT

apt-get update -qq
apt-get upgrade -y -qq
apt_install \
    curl wget git unzip zip gnupg2 ca-certificates lsb-release \
    software-properties-common apt-transport-https gettext-base \
    ufw fail2ban logrotate cron \
    unattended-upgrades apt-listchanges

# Unattended upgrades — security patches applied automatically
cp "${SCRIPT_DIR}/config/unattended-upgrades.conf" \
   /etc/apt/apt.conf.d/50unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
success "Unattended-upgrades configured"

# ── 3. PHP ────────────────────────────────────────────────────────────────────
section "PHP ${PHP_VERSION}"

if ! php -v 2>/dev/null | grep -q "PHP ${PHP_VERSION}"; then
    add-apt-repository -y ppa:ondrej/php
    apt-get update -qq
fi
apt_install \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-zip" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-bcmath" \
    "php${PHP_VERSION}-intl" \
    "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-sqlite3" \
    "php${PHP_VERSION}-redis" \
    "php${PHP_VERSION}-tokenizer" \
    "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-imagick"

# OPcache production settings
mkdir -p "/etc/php/${PHP_VERSION}/fpm/conf.d"
cp "${SCRIPT_DIR}/config/opcache-prod.ini" \
   "/etc/php/${PHP_VERSION}/fpm/conf.d/10-opcache-prod.ini"

# PHP-FPM log directory
mkdir -p /var/log/php
chown "www-data:adm" /var/log/php
chmod 750 /var/log/php

# Pre-stage the app pool BEFORE starting the service so FPM always has a
# valid pool on both first-run and re-run.
export APP_NAME APP_USER APP_DIR PHP_VERSION
render_template \
    "${SCRIPT_DIR}/config/php-fpm-pool.conf.tmpl" \
    "/etc/php/${PHP_VERSION}/fpm/pool.d/${APP_NAME}.conf"

# Disable the default www pool now that the app pool is in place.
[[ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]] && \
    mv "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" \
       "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf.disabled"

# All packages installed — remove the service-start block and clear the trap.
_remove_policy_rc
trap - EXIT

systemctl enable "php${PHP_VERSION}-fpm"
systemctl restart "php${PHP_VERSION}-fpm"
success "PHP ${PHP_VERSION}-FPM configured"

# ── 4. Composer ───────────────────────────────────────────────────────────────
section "Composer"
# These env vars are required when running Composer as root:
#   ALLOW_SUPERUSER skips the "don't run as root" warning and disables
#   the update-check network call that causes hangs in restricted environments.
export COMPOSER_ALLOW_SUPERUSER=1
export COMPOSER_NO_INTERACTION=1
export COMPOSER_HOME=/root/.composer

if ! command -v composer &>/dev/null; then
    _tmpdir="$(mktemp -d)"
    info "Downloading Composer installer..."
    curl -fsSL --max-time 60 https://getcomposer.org/installer \
        -o "${_tmpdir}/composer-setup.php" \
        || error "Failed to download Composer installer (check network)"
    EXPECTED_SIG="$(curl -fsSL --max-time 15 https://composer.github.io/installer.sig \
        || error "Failed to fetch Composer signature (check network)")"
    ACTUAL_SIG="$(php -r "echo hash_file('sha384','${_tmpdir}/composer-setup.php');")"
    [[ "$EXPECTED_SIG" == "$ACTUAL_SIG" ]] \
        || { rm -rf "$_tmpdir"; error "Composer installer checksum mismatch — possible MITM"; }
    php "${_tmpdir}/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
    rm -rf "$_tmpdir"
fi
success "Composer ready at $(command -v composer)"

# ── 5. Node.js & pnpm ────────────────────────────────────────────────────────
section "Node.js ${NODE_VERSION} & pnpm"
if ! node -v 2>/dev/null | grep -qE "^v${NODE_VERSION}"; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    apt_install nodejs
fi
npm install -g corepack 2>/dev/null || true
corepack enable
corepack prepare pnpm@latest --activate 2>/dev/null || true
success "Node $(node -v) | pnpm $(pnpm -v 2>/dev/null || echo 'n/a')"

# ── 6. MySQL ──────────────────────────────────────────────────────────────────
section "MySQL 8"
if ! command -v mysql &>/dev/null; then
    apt_install mysql-server
    systemctl enable --now mysql
fi

# Security hardening — idempotent via IF NOT EXISTS / DROP IF EXISTS
mysql -u root <<SQL
-- Remove anonymous accounts
DELETE FROM mysql.user WHERE User='';
-- Remove remote root access
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
-- Drop test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
-- Create app database and user
CREATE DATABASE IF NOT EXISTS \`${APP_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_NAME}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${APP_NAME}\`.* TO '${APP_NAME}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Bind MySQL to localhost only
MYSQL_CONF="/etc/mysql/mysql.conf.d/mysqld.cnf"
if [[ -f "$MYSQL_CONF" ]] && ! grep -q "^bind-address.*127.0.0.1" "$MYSQL_CONF"; then
    sed -i 's/^bind-address\s*=.*/bind-address = 127.0.0.1/' "$MYSQL_CONF" || \
        echo "bind-address = 127.0.0.1" >> "$MYSQL_CONF"
    systemctl restart mysql
fi
success "MySQL configured and hardened"

# ── 7. Valkey ─────────────────────────────────────────────────────────────────
section "Valkey"
# Valkey is the open-source Redis-compatible successor (same protocol/clients).
# Package is in Ubuntu 24.04 universe; enable universe first.
add-apt-repository -y universe 2>/dev/null || true
apt-get update -qq
if ! command -v valkey-server &>/dev/null; then
    apt_install valkey
fi

# Valkey's config is at /etc/valkey/valkey.conf; we append a single `include`
# at the END so our settings override the defaults above it.
VALKEY_APP_CONF="/etc/valkey/valkey-app.conf"
VALKEY_MAIN="/etc/valkey/valkey.conf"

export REDIS_PASS
render_template \
    "${SCRIPT_DIR}/config/valkey-app.conf.tmpl" \
    "${VALKEY_APP_CONF}" \
    "640" "valkey:valkey"

if ! grep -q "^include ${VALKEY_APP_CONF}" "${VALKEY_MAIN}" 2>/dev/null; then
    printf '\n# App-specific overrides (generated by laravel-setup)\ninclude %s\n' \
        "${VALKEY_APP_CONF}" >> "${VALKEY_MAIN}"
fi

systemctl enable --now valkey-server
systemctl restart valkey-server
success "Valkey configured with authentication"

# ── 8. Nginx ──────────────────────────────────────────────────────────────────
section "Nginx"
if ! command -v nginx &>/dev/null; then
    apt_install nginx
fi

# Rate-limit zone (http context)
export APP_NAME DOMAIN PHP_VERSION APP_DIR WEBHOOK_PATH
render_template \
    "${SCRIPT_DIR}/config/nginx-rate-limit.conf.tmpl" \
    "/etc/nginx/conf.d/${APP_NAME}-rate-limit.conf"

# HTTP-only config first (for ACME challenge before we have a cert)
mkdir -p /var/www/html
cat > "/etc/nginx/sites-available/${APP_NAME}-http" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/html;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://${DOMAIN}\$request_uri; }
}
EOF
ln -sf "/etc/nginx/sites-available/${APP_NAME}-http" \
       "/etc/nginx/sites-enabled/${APP_NAME}-http"
rm -f /etc/nginx/sites-enabled/default

nginx -t || error "Nginx config test failed"
systemctl enable --now nginx
systemctl reload nginx
success "Nginx configured (HTTP-only, pending TLS)"

# ── 9. Certbot / TLS ──────────────────────────────────────────────────────────
section "TLS — Let's Encrypt"
if ! command -v certbot &>/dev/null; then
    apt_install certbot python3-certbot-nginx
fi

if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    certbot certonly \
        --webroot \
        -w /var/www/html \
        -d "${DOMAIN}" \
        -d "www.${DOMAIN}" \
        --email "${CERTBOT_EMAIL}" \
        --agree-tos \
        --non-interactive
    success "TLS certificate obtained"
else
    success "TLS certificate already present"
fi

# Now install the full HTTPS config
render_template \
    "${SCRIPT_DIR}/config/nginx.conf.tmpl" \
    "/etc/nginx/sites-available/${APP_NAME}" \
    "644"

rm -f "/etc/nginx/sites-enabled/${APP_NAME}-http" \
      "/etc/nginx/sites-available/${APP_NAME}-http"
ln -sf "/etc/nginx/sites-available/${APP_NAME}" \
       "/etc/nginx/sites-enabled/${APP_NAME}"

# Ensure DH params exist (certbot usually creates them, but guard anyway)
if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
    openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 2>/dev/null
fi

nginx -t || error "Nginx TLS config test failed"
systemctl reload nginx
success "Nginx TLS site active"

# ── 10. Repository & deploy key ────────────────────────────────────────────────
section "Deploy key & repository"
SSH_HOME="/home/${APP_USER}/.ssh"

# Use a real home outside APP_DIR for SSH keys (APP_DIR may not exist yet)
if getent passwd "${APP_USER}" | cut -d: -f6 | grep -q "^${APP_DIR}$"; then
    # System user with APP_DIR as home — keep keys there
    true
fi

# If the system user has no separate home, store keys under /etc/<APP_NAME>/ssh
SSH_HOME_REAL="/etc/${APP_NAME}/ssh"
mkdir -p "${SSH_HOME_REAL}"
chmod 700 "${SSH_HOME_REAL}"
chown "${APP_USER}:${APP_USER}" "${SSH_HOME_REAL}" 2>/dev/null || chown "root:root" "${SSH_HOME_REAL}"

DEPLOY_KEY="${SSH_HOME_REAL}/id_ed25519"
if [[ ! -f "${DEPLOY_KEY}" ]]; then
    sudo -u "${APP_USER}" ssh-keygen -t ed25519 -C "deploy@${DOMAIN}" -f "${DEPLOY_KEY}" -N "" 2>/dev/null || \
        ssh-keygen -t ed25519 -C "deploy@${DOMAIN}" -f "${DEPLOY_KEY}" -N ""
    chown "${APP_USER}" "${DEPLOY_KEY}" "${DEPLOY_KEY}.pub" 2>/dev/null || true
fi

# Trust GitHub's host key (TOFU — write once)
if ! grep -q "github.com" "${SSH_HOME_REAL}/known_hosts" 2>/dev/null; then
    ssh-keyscan github.com >> "${SSH_HOME_REAL}/known_hosts" 2>/dev/null
    chown "${APP_USER}" "${SSH_HOME_REAL}/known_hosts" 2>/dev/null || true
fi

# Write SSH client config for this user
SSH_CONFIG="${SSH_HOME_REAL}/config"
cat > "${SSH_CONFIG}" <<EOF
Host github.com
    IdentityFile ${DEPLOY_KEY}
    UserKnownHostsFile ${SSH_HOME_REAL}/known_hosts
EOF
chmod 600 "${SSH_CONFIG}"

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
warn "Add this deploy key to your GitHub repository:"
warn "  Settings → Deploy Keys → Add deploy key (read-only is enough)"
echo ""
cat "${DEPLOY_KEY}.pub"
echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
read -rp "Press Enter once the deploy key has been added to GitHub..."

# Clone repository
mkdir -p "${APP_DIR}"
if [[ ! -d "${APP_DIR}/.git" ]]; then
    GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o UserKnownHostsFile=${SSH_HOME_REAL}/known_hosts" \
        git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${APP_DIR}"
fi
chown -R "${APP_USER}:www-data" "${APP_DIR}"
success "Repository ready at ${APP_DIR}"

# ── 12. Laravel .env ──────────────────────────────────────────────────────────
section "Laravel environment (.env)"
if [[ ! -f "${APP_DIR}/.env" ]]; then
    cat > "${APP_DIR}/.env" <<EOF
APP_NAME="${APP_NAME}"
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=https://${DOMAIN}

LOG_CHANNEL=stack
LOG_STACK=single
LOG_LEVEL=warning

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${APP_NAME}
DB_USERNAME=${APP_NAME}
DB_PASSWORD=${DB_PASS}

SESSION_DRIVER=redis
SESSION_LIFETIME=120
SESSION_ENCRYPT=true
SESSION_PATH=/
SESSION_DOMAIN=.${DOMAIN}

FILESYSTEM_DISK=public
QUEUE_CONNECTION=redis
CACHE_STORE=redis
BROADCAST_CONNECTION=log

REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=${REDIS_PASS}
REDIS_PORT=6379

MAIL_MAILER=smtp
MAIL_HOST=127.0.0.1
MAIL_PORT=25
MAIL_FROM_ADDRESS=noreply@${DOMAIN}
MAIL_FROM_NAME="${APP_NAME}"
EOF
    chown "${APP_USER}:www-data" "${APP_DIR}/.env"
    chmod 640 "${APP_DIR}/.env"
    success ".env created"
else
    warn ".env already exists — skipped (credentials untouched)"
fi

# Update socket path in nginx config to match pool-specific socket
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}"
if grep -q "php${PHP_VERSION}-fpm.sock" "${NGINX_CONF}"; then
    sed -i "s|php${PHP_VERSION}-fpm.sock|php${PHP_VERSION}-fpm-${APP_NAME}.sock|g" "${NGINX_CONF}"
    nginx -t && systemctl reload nginx
fi

# ── 13. Initial deployment ────────────────────────────────────────────────────
section "Initial deployment"

# Run as the app user
GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o UserKnownHostsFile=${SSH_HOME_REAL}/known_hosts" \
    sudo -u "${APP_USER}" bash "${SCRIPT_DIR}/deploy.sh" --initial
success "Application deployed"

# ── 14. Supervisor ────────────────────────────────────────────────────────────
section "Supervisor"
apt_install supervisor
render_template \
    "${SCRIPT_DIR}/config/supervisor.conf.tmpl" \
    "/etc/supervisor/conf.d/${APP_NAME}.conf"

systemctl enable --now supervisor
supervisorctl reread
supervisorctl update
success "Supervisor configured"

# ── 15. Fail2ban ─────────────────────────────────────────────────────────────
section "Fail2ban"
render_template \
    "${SCRIPT_DIR}/config/fail2ban/filter-app.conf.tmpl" \
    "/etc/fail2ban/filter.d/${APP_NAME}-admin.conf"
render_template \
    "${SCRIPT_DIR}/config/fail2ban/jail-app.conf.tmpl" \
    "/etc/fail2ban/jail.d/${APP_NAME}.conf"

systemctl enable --now fail2ban
fail2ban-client reload 2>/dev/null || systemctl restart fail2ban
success "Fail2ban configured"

# ── 16. UFW firewall ──────────────────────────────────────────────────────────
section "Firewall (UFW)"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH    comment "SSH"
ufw allow 'Nginx Full' comment "HTTP + HTTPS"
# Only enable if not already active (avoid disrupting existing rules)
if ufw status | grep -q "inactive"; then
    ufw --force enable
fi
success "UFW firewall active"

# ── 17. SSH hardening ─────────────────────────────────────────────────────────
section "SSH hardening"
warn "Password authentication will be DISABLED. Ensure your SSH key works!"
cp "${SCRIPT_DIR}/config/sshd-hardening.conf" \
   /etc/ssh/sshd_config.d/99-hardening.conf
chmod 600 /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t || error "sshd config test failed — check /etc/ssh/sshd_config"
systemctl reload ssh 2>/dev/null || systemctl reload sshd
success "SSH hardened (key-only auth, root login restricted)"

# ── 18. Logrotate ─────────────────────────────────────────────────────────────
section "Log rotation"
render_template \
    "${SCRIPT_DIR}/config/logrotate.conf.tmpl" \
    "/etc/logrotate.d/${APP_NAME}"
success "Log rotation configured"

# ── 19. Daily backup cron ─────────────────────────────────────────────────────
section "Daily backup cron"
render_template \
    "${SCRIPT_DIR}/config/backup.cron.tmpl" \
    "/etc/cron.d/${APP_NAME}-backup" \
    "644"
success "Daily backup cron installed (02:30 daily, kept ${KEEP_BACKUPS} days)"

# ── 20. Sudoers drop-in for deploy user ───────────────────────────────────────
section "Sudoers"
render_template \
    "${SCRIPT_DIR}/config/sudoers-deploy.tmpl" \
    "/etc/sudoers.d/${APP_USER}" \
    "440"
visudo -cf "/etc/sudoers.d/${APP_USER}" || { rm "/etc/sudoers.d/${APP_USER}"; error "Sudoers syntax error"; }
success "Sudoers configured for ${APP_USER}"

# ── 21. Deploy-on-push (webhook) ──────────────────────────────────────────────
if [[ "${DEPLOY_ON_PUSH}" == "true" ]]; then
    section "Deploy-on-push (webhook)"
    apt_install webhook

    mkdir -p /etc/webhook
    render_template \
        "${SCRIPT_DIR}/config/webhook.hook.json.tmpl" \
        "/etc/webhook/${APP_NAME}-hooks.json" \
        "640" "root:${APP_USER}"

    # Wrapper script invoked by webhook
    cat > "/usr/local/bin/${APP_NAME}-deploy" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec bash ${SCRIPT_DIR}/deploy.sh >> ${APP_DIR}/storage/logs/deploy.log 2>&1
EOF
    chmod 750 "/usr/local/bin/${APP_NAME}-deploy"
    chown "${APP_USER}" "/usr/local/bin/${APP_NAME}-deploy"

    # Systemd unit
    render_template \
        "${SCRIPT_DIR}/config/webhook.service.tmpl" \
        "/etc/systemd/system/webhook-${APP_NAME}.service" \
        "644"
    systemctl daemon-reload
    systemctl enable --now "webhook-${APP_NAME}"

    # Nginx snippet
    mkdir -p /etc/nginx/snippets
    render_template \
        "${SCRIPT_DIR}/config/nginx-webhook.conf.tmpl" \
        "/etc/nginx/snippets/${APP_NAME}-webhook.conf"

    # Activate the include in the site config
    NGINX_SITE="/etc/nginx/sites-available/${APP_NAME}"
    if ! grep -q "${APP_NAME}-webhook.conf" "${NGINX_SITE}"; then
        # Insert include just before closing brace
        sed -i "s|# include /etc/nginx/snippets/${APP_NAME}-webhook.conf;|include /etc/nginx/snippets/${APP_NAME}-webhook.conf;|" "${NGINX_SITE}" || \
        sed -i "/^}$/i\\    include /etc/nginx/snippets/${APP_NAME}-webhook.conf;" "${NGINX_SITE}"
    fi
    nginx -t && systemctl reload nginx

    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    warn "Configure this webhook in your GitHub repository:"
    warn "  Settings → Webhooks → Add webhook"
    echo ""
    info "  Payload URL  : https://${DOMAIN}/__deploy/${WEBHOOK_PATH}"
    info "  Content type : application/json"
    info "  Secret       : (see ${SECRETS_FILE})"
    info "  Events       : Just the push event"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Setup complete"
echo -e "${GREEN}${BOLD}"
echo "  Domain     : https://${DOMAIN}"
echo "  App dir    : ${APP_DIR}"
echo "  App user   : ${APP_USER}"
echo "  Secrets    : ${SECRETS_FILE}"
echo "  Backups    : ${BACKUP_DIR}  (daily 02:30, keep ${KEEP_BACKUPS})"
echo ""
echo -e "${NC}"
info "Secrets (DB password, Valkey password, etc.) are stored in:"
info "  ${SECRETS_FILE}  (mode 600, root only)"
info ""
info "To deploy manually:  sudo bash ${SCRIPT_DIR}/deploy.sh"
info "To restore:          sudo bash ${SCRIPT_DIR}/lib/restore.sh --last"
info "To list backups:     sudo bash ${SCRIPT_DIR}/lib/restore.sh --list"
success "Server is live at https://${DOMAIN}"
