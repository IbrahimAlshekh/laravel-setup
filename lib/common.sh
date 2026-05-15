#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared helpers sourced by setup.sh and deploy.sh
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# After sourcing, call: load_deploy_env  (reads .env.deploy + derives vars)
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Output helpers ────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}▶${NC} $*"; }
success() { echo -e "${GREEN}✔${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✘ ERROR:${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}═══ $* ═══${NC}"; }

# ── Root guard ────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root: sudo $0"
}

# ── Locate .env.deploy (walks up from caller's dir or uses DEPLOY_ENV_FILE) ──
find_env_file() {
    local candidate="${DEPLOY_ENV_FILE:-}"
    if [[ -z "$candidate" ]]; then
        # Walk from the script's directory up to find .env.deploy
        local dir
        dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        while [[ "$dir" != "/" ]]; do
            [[ -f "${dir}/.env.deploy" ]] && { candidate="${dir}/.env.deploy"; break; }
            dir="$(dirname "$dir")"
        done
    fi
    echo "$candidate"
}

# ── Load .env.deploy and derive computed vars ─────────────────────────────────
load_deploy_env() {
    local env_file
    env_file="$(find_env_file)"
    [[ -z "$env_file" || ! -f "$env_file" ]] && \
        error "No .env.deploy found. Copy .env.deploy.example → .env.deploy and fill in the 9 values."

    # shellcheck source=/dev/null
    source "$env_file"

    # Required vars — fail fast with a clear message
    local required=(DOMAIN CERTBOT_EMAIL REPO_URL REPO_BRANCH APP_DIR BACKUP_DIR KEEP_BACKUPS PHP_VERSION DEPLOY_ON_PUSH)
    for var in "${required[@]}"; do
        [[ -n "${!var:-}" ]] || error "Missing required variable \$${var} in .env.deploy"
    done

    # Derived vars (not user-supplied)
    APP_NAME="${APP_NAME:-$(basename "$APP_DIR")}"
    APP_USER="${APP_USER:-$APP_NAME}"
    NODE_VERSION="${NODE_VERSION:-22}"
    SECRETS_FILE="/etc/${APP_NAME}/secrets.env"
    DEPLOY_LOG="${APP_DIR}/storage/logs/deploy.log"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

    export DOMAIN CERTBOT_EMAIL REPO_URL REPO_BRANCH APP_DIR BACKUP_DIR
    export KEEP_BACKUPS PHP_VERSION DEPLOY_ON_PUSH
    export APP_NAME APP_USER NODE_VERSION SECRETS_FILE DEPLOY_LOG SCRIPT_DIR
}

# ── Load secrets (requires secrets.env to already exist) ─────────────────────
load_secrets() {
    [[ -f "$SECRETS_FILE" ]] || error "Secrets file not found: $SECRETS_FILE  (run setup.sh first)"
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
}

# ── apt-get wrapper ───────────────────────────────────────────────────────────
apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

# ── Render a .tmpl file via envsubst and install it ───────────────────────────
# Usage: render_template src.tmpl /dest/path [mode] [owner]
render_template() {
    local src="$1" dest="$2" mode="${3:-644}" owner="${4:-root:root}"
    [[ -f "$src" ]] || error "Template not found: $src"
    envsubst < "$src" > "$dest"
    chmod "$mode" "$dest"
    chown "$owner" "$dest"
}
