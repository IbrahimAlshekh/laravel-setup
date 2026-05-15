#!/usr/bin/env bash
# =============================================================================
# secrets.sh — Manage per-application secrets stored in /etc/<app>/secrets.env
#
# The secrets file is owned by root, mode 600, so only root (and sudo) can
# read it. No secret is ever echoed to stdout or shown in process listings.
#
# Usage (from setup.sh after load_deploy_env):
#   source lib/secrets.sh
#   init_secrets          # idempotent: generate missing, preserve existing
#   load_secrets          # re-export all secrets into the current environment
# =============================================================================

# Generate a cryptographically random alphanumeric string of given length.
_gen_secret() {
    local length="${1:-32}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Write or update a single key=value line in the secrets file.
# Existing value is preserved (idempotent).
secret_ensure() {
    local key="$1"
    local default_fn="$2"   # name of a function that returns the default value

    # If key already set in environment (loaded from file), skip.
    [[ -n "${!key:-}" ]] && return 0

    local value
    value="$("$default_fn")"

    # Append to file.
    printf '%s=%s\n' "$key" "$value" >> "$SECRETS_FILE"
    # Export into current shell.
    export "${key}"="${value}"
}

# Initialise the secrets file, generating any missing values.
# Safe to call repeatedly — existing secrets are never overwritten.
init_secrets() {
    local dir
    dir="$(dirname "$SECRETS_FILE")"
    mkdir -p "$dir"
    chmod 700 "$dir"

    # Create file if absent; lock it down immediately.
    if [[ ! -f "$SECRETS_FILE" ]]; then
        touch "$SECRETS_FILE"
        chmod 600 "$SECRETS_FILE"
        chown root:root "$SECRETS_FILE"
    fi

    # Load any already-generated secrets so secret_ensure can detect them.
    # shellcheck source=/dev/null
    source "$SECRETS_FILE" 2>/dev/null || true

    # DB root password
    secret_ensure DB_ROOT_PASS _gen_secret
    # DB app user password
    secret_ensure DB_PASS      _gen_secret
    # Valkey password (stored as REDIS_PASS — Laravel's config name is REDIS_*)
    secret_ensure REDIS_PASS   _gen_secret
    # Webhook HMAC secret (only used when DEPLOY_ON_PUSH=true)
    secret_ensure WEBHOOK_SECRET _gen_secret
    # Random path suffix for the webhook nginx location
    secret_ensure WEBHOOK_PATH _gen_webhook_path

    success "Secrets initialised → ${SECRETS_FILE}"
}

_gen_webhook_path() {
    openssl rand -hex 16
}

# Re-export all secrets into the environment (for use in deploy.sh / backup.sh)
load_secrets() {
    [[ -f "$SECRETS_FILE" ]] || error "Secrets file not found: ${SECRETS_FILE}  (run setup.sh first)"
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
}
