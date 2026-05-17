# Laravel VPS Setup — Ansible

Ansible playbooks for deploying Laravel applications on a fresh Ubuntu 22.04 or 24.04 VPS. Idempotent — safe to re-run. Supports multiple isolated sites on the same server.

## What gets installed

| Component | Details |
|-----------|---------|
| PHP-FPM | Version configurable (default 8.4), OPcache production settings, per-site isolated pool |
| Nginx | HTTPS with TLS 1.2/1.3, HSTS, security headers, rate-limiting on login endpoints |
| MySQL 8 | Per-site database + user, localhost-only binding, anonymous accounts removed |
| Valkey | Redis-compatible, password-protected, dangerous commands disabled, localhost-only |
| Supervisor | Queue workers (×2) + scheduler per site, auto-restart |
| Fail2ban | Login brute-force, bot scanner, rate-limit violation, SSH brute-force jails |
| UFW | Default deny, allows SSH / HTTP / HTTPS only |
| Certbot | Let's Encrypt TLS certificate, auto-renew, DH params |
| SSH hardening | Key-only auth, strong ciphers, root login restricted |
| Unattended upgrades | Automatic security patches, auto-reboot for kernel updates |
| Logrotate | Daily rotation of Laravel logs, 14-day retention |
| Backup | Daily snapshots (DB + storage + git ref), configurable retention |

## Prerequisites

- Fresh Ubuntu 22.04 or 24.04 VPS with root SSH access
- Ansible 2.14+ on your local machine
- Domain DNS A record pointing to the server IP (required for Let's Encrypt)
- A private GitHub repository for your Laravel app

## Quickstart

### 1. Install dependencies

```bash
pip install ansible
make deps   # installs community.mysql and community.general collections
```

### 2. Configure the server inventory

Edit `inventory/hosts.yml`:

```yaml
all:
  hosts:
    laravel_server:
      ansible_host: YOUR_SERVER_IP
      ansible_user: root
      ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

### 3. Set up the server (once per VPS)

Installs nginx, PHP, MySQL, Valkey, Node.js, Composer, Supervisor, fail2ban, UFW, and SSH hardening. No application-specific configuration.

```bash
make setup
```

### 4. Add secrets for your site

Generate a strong database password:

```bash
openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
```

Create `sites/<repo>/vault.yml` and encrypt it:

```bash
mkdir -p sites/myrepo
cat > sites/myrepo/vault.yml <<EOF
db_pass: "your-strong-password"
EOF

ansible-vault encrypt sites/myrepo/vault.yml
```

Save the vault password to `.vault-pass` (already gitignored):

```bash
echo "your-vault-password" > .vault-pass
chmod 600 .vault-pass
```

### 5. Set up the application site

```bash
make setup SITE=AtheerSolutions/castlegroup:dev \
           DOMAIN=castlegroup.example.com \
           EMAIL=admin@example.com
```

This will:
1. Create an isolated system user, PHP-FPM pool, and MySQL database for this site
2. **Pause and print a deploy public key** — add it to GitHub before continuing (Settings → Deploy Keys → Add deploy key, read-only)
3. Clone your repository and run the initial deployment
4. Obtain a TLS certificate from Let's Encrypt
5. Configure Supervisor workers, fail2ban jails, and daily backups
6. Print a summary with your live URL

### 6. Deploy

```bash
make deploy SITE=AtheerSolutions/castlegroup:dev
```

## Command reference

### `make setup`

Installs all server software. Run once per VPS.

```bash
make setup
```

### `make setup SITE=ORG/REPO:BRANCH`

Provisions one application site. Re-running is safe and updates configuration.

```bash
make setup SITE=AtheerSolutions/castlegroup:dev \
           DOMAIN=castlegroup.example.com \
           EMAIL=admin@example.com
```

| Parameter | Description |
|-----------|-------------|
| `SITE` | `ORG/REPO:BRANCH` — GitHub org, repository name, and branch to deploy |
| `DOMAIN` | Bare domain (no `www`, no `https://`) — used for nginx vhost and TLS cert |
| `EMAIL` | Email for Let's Encrypt expiry notifications |

### `make deploy SITE=ORG/REPO:BRANCH`

Pulls the latest code, installs dependencies, runs migrations, builds assets, and restarts workers.

```bash
make deploy SITE=AtheerSolutions/castlegroup:dev
```

### `make backup SITE=ORG/REPO:BRANCH`

Triggers a manual backup snapshot.

```bash
make backup SITE=AtheerSolutions/castlegroup:dev
```

### `make restore SITE=ORG/REPO:BRANCH`

Restores the most recent backup snapshot.

```bash
make restore SITE=AtheerSolutions/castlegroup:dev

# Restore a specific snapshot
make restore SITE=AtheerSolutions/castlegroup:dev TIMESTAMP=20240115_023001
```

### Global options

| Option | Description |
|--------|-------------|
| `TAGS=tag1,tag2` | Run only the specified Ansible role(s), skipping the rest |
| `VERBOSE=1` | Show full Ansible task output (`-v`) |
| `VAULT_PASS_FILE=path` | Vault password file (default: `.vault-pass`) |

## Day-to-day operations

On the server, per-site scripts are available at `/usr/local/bin/<repo>-backup` and `/usr/local/bin/<repo>-restore`:

```bash
# List available backup snapshots
sudo castlegroup-restore --list

# Restore most recent snapshot
sudo castlegroup-restore --last

# Restore a specific snapshot
sudo castlegroup-restore --timestamp 20240115_023001

# Run a manual backup
sudo castlegroup-backup
```

## Multiple sites on the same server

Each `make setup SITE=...` call creates a fully isolated environment (system user, PHP-FPM pool, MySQL database, nginx vhost, TLS cert). Run it once per site:

```bash
make setup SITE=MyOrg/shop:main    DOMAIN=shop.example.com    EMAIL=admin@example.com
make setup SITE=MyOrg/blog:main    DOMAIN=blog.example.com    EMAIL=admin@example.com
make setup SITE=MyOrg/api:main     DOMAIN=api.example.com     EMAIL=admin@example.com
```

Each site gets its own `sites/<repo>/vault.yml` for secrets.

## Deploy-on-push (optional)

Add `deploy_on_push: true` to `sites/<repo>/vars.yml` and add a `webhook_secret` to the vault file:

```yaml
# sites/myrepo/vars.yml
deploy_on_push: true
```

```yaml
# sites/myrepo/vault.yml (before encrypting)
db_pass: "..."
webhook_secret: "your-hmac-secret"
webhook_path: "/webhook/secret-path"
```

Re-run `make setup SITE=...` to install the webhook listener. The provisioning output will display the webhook URL and GitHub configuration instructions (Settings → Webhooks).

## Project structure

```
├── Makefile                     # make setup / deploy / backup / restore
├── requirements.yml             # Ansible Galaxy collection dependencies
├── inventory/
│   ├── hosts.yml                # Server inventory (IP, SSH key)
│   └── group_vars/all/
│       ├── vars.yml             # Server-level defaults (php_version, keep_backups)
│       └── vault.yml            # Server-level secrets (redis_pass)
├── sites/
│   ├── example/
│   │   ├── vars.yml             # Site option overrides template
│   │   └── vault.yml            # Site secrets template
│   └── <repo>/
│       ├── vars.yml             # Optional overrides (deploy_on_push, php_version)
│       └── vault.yml            # Encrypted site secrets (db_pass, webhook_secret)
├── playbooks/
│   ├── server-setup.yml         # Server software install (make setup)
│   ├── site-setup.yml           # Per-site provisioning (make setup SITE=...)
│   ├── deploy.yml               # Deploy latest code
│   ├── backup.yml               # Trigger backup
│   ├── restore.yml              # Restore snapshot
│   ├── provision.yml            # Convenience: server-setup + site-setup in one run
│   └── tasks/
│       └── deploy-steps.yml     # Shared deploy steps (composer, migrate, build, cache)
└── roles/
    ├── common/                  # Base packages, unattended-upgrades
    ├── php/                     # PHP-FPM install (server) + per-site pool
    ├── composer/                # Composer installation
    ├── nodejs/                  # Node.js + pnpm
    ├── mysql/                   # MySQL install + hardening (server) + per-site DB/user
    ├── valkey/                  # Valkey (Redis-compatible) config
    ├── nginx/                   # Nginx install (server) + per-site vhost
    ├── certbot/                 # Certbot install (server) + per-site TLS cert
    ├── ufw/                     # Firewall rules
    ├── ssh_hardening/           # SSH hardening
    ├── fail2ban/                # Brute-force protection (server install + per-site jails)
    ├── supervisor/              # Supervisor install (server) + per-site workers
    ├── logrotate/               # Log rotation
    ├── laravel_app/             # App user, deploy key, repo clone, .env, backup scripts
    └── webhook/                 # Deploy-on-push webhook listener
```

## Variable sources

Variables are resolved in this order (later sources win):

| Source | Contains |
|--------|----------|
| `inventory/group_vars/all/vars.yml` | Server defaults: `php_version`, `keep_backups` |
| `inventory/group_vars/all/vault.yml` | Server secrets: `vault_redis_pass` |
| `sites/<repo>/vars.yml` | Site overrides: `deploy_on_push`, `php_version` |
| `sites/<repo>/vault.yml` | Site secrets: `db_pass`, `webhook_secret` |
| `SITE=ORG/REPO:BRANCH` | Derived: `app_name`, `app_dir`, `repo_url`, `repo_branch` |
| `DOMAIN=`, `EMAIL=` | `domain`, `certbot_email` |

## Secrets management

Site secrets (`db_pass`, `webhook_secret`) live in `sites/<repo>/vault.yml`, encrypted with `ansible-vault`. Server-level secrets (`redis_pass`) live in `inventory/group_vars/all/vault.yml`. Neither is ever committed in plain text.

On the server, secrets are written to `/etc/<app_name>/secrets.env` (mode 640, readable only by root and the app user).

To rotate a secret: update the vault file, re-encrypt, and re-run `make setup SITE=...` (idempotent).

## Backups

Daily snapshots run at 02:30 AM via cron. Each snapshot contains:
- Compressed MySQL dump (`.sql.gz`)
- Storage tarball (`storage/app` only, excludes logs/framework)
- Git commit reference for code rollback

`keep_backups` (default: 7) controls how many sets are retained. A pre-deploy backup is also taken automatically before each `make deploy`.

## Running individual roles

Use `TAGS=` to re-apply only a specific part of the playbook without running everything else. This is useful for pushing a config change without re-provisioning the whole site.

```bash
# Re-apply only the nginx vhost config for one site
make setup SITE=AtheerSolutions/castlegroup:dev TAGS=nginx

# Re-apply only the Supervisor workers for one site
make setup SITE=AtheerSolutions/castlegroup:dev TAGS=supervisor

# Re-apply only the PHP-FPM pool for one site
make setup SITE=AtheerSolutions/castlegroup:dev TAGS=php

# Re-apply only server-level nginx install (no SITE needed)
make setup TAGS=nginx
```

Available tags for `make setup SITE=...`:

| Tag | What it updates |
|-----|----------------|
| `nginx` | nginx vhost config + reload |
| `php` | PHP-FPM pool config + restart |
| `mysql` | MySQL database and user |
| `supervisor` | Supervisor worker config + restart |
| `certbot` / `tls` | TLS certificate (obtain or renew) |
| `app` | App user, deploy key, `.env`, backup scripts |
| `fail2ban` | fail2ban jails |
| `logrotate` | Log rotation config |
| `webhook` | Deploy-on-push webhook listener |

Available tags for `make setup` (server-level, no `SITE`):

`common`, `php`, `composer`, `nodejs`, `mysql`, `valkey`, `nginx`, `certbot`, `supervisor`, `fail2ban`, `ufw`, `ssh`

## Security posture

- SSH: key-only auth, password auth disabled, root login restricted, strong ciphers only
- Firewall: UFW default deny — only ports 22, 80, 443 open
- MySQL: localhost-only, no anonymous accounts, no remote root, per-site users with minimal privileges
- Valkey: localhost-only, password-required, dangerous commands disabled
- PHP-FPM: `open_basedir` restriction per site, dangerous functions disabled
- Nginx: HSTS, CSP, X-Frame-Options, rate-limiting on auth endpoints (5 req/min)
- Fail2ban: login brute-force, bot scanner, rate-limit violation, SSH brute-force jails
- Unattended-upgrades: automatic security patches with auto-reboot for kernel updates
- Secrets: ansible-vault encrypted at rest; mode 640 on server
