# Laravel VPS Setup — Ansible

Ansible playbooks for deploying a Laravel application on a fresh Ubuntu 22.04 or 24.04 VPS. Idempotent — safe to re-run.

## What gets installed

| Component | Details |
|-----------|---------|
| PHP-FPM | Version configurable (default 8.4), OPcache production settings, dedicated pool |
| Nginx | HTTPS with TLS 1.2/1.3, HSTS, security headers, rate-limiting on login endpoints |
| MySQL 8 | App database + user, localhost-only binding, anonymous accounts removed |
| Valkey | Redis-compatible, password-protected, dangerous commands disabled, localhost-only |
| Supervisor | Queue workers (×2) + scheduler, auto-restart |
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

### 2. Configure your server

Edit `inventory/hosts.yml`:

```yaml
all:
  hosts:
    laravel_server:
      ansible_host: YOUR_SERVER_IP
      ansible_user: root
      ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

### 3. Set deployment variables

Edit `group_vars/all/vars.yml` and fill in your values:

```yaml
domain: "example.com"
certbot_email: "admin@example.com"
repo_url: "git@github.com:your-org/your-repo.git"
repo_branch: "main"
app_dir: "/var/www/myapp"
backup_dir: "/var/backups/myapp"
keep_backups: 7
php_version: "8.4"
deploy_on_push: false
```

### 4. Set secrets

Generate strong random secrets:

```bash
openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
```

Fill in `group_vars/all/vault.yml`, then encrypt it:

```bash
ansible-vault encrypt group_vars/all/vault.yml
```

Save the vault password to `.vault-pass` (already gitignored):

```bash
echo "your-vault-password" > .vault-pass
chmod 600 .vault-pass
```

### 5. Provision the server

```bash
make provision
```

This will:
1. Install and configure the full stack (~5–10 min)
2. **Pause and print a deploy public key** — add it to GitHub before continuing (Settings → Deploy Keys → Add deploy key, read-only)
3. Clone your repository and run the initial deployment
4. Print a summary with your live URL

## Day-to-day operations

| Task | Command |
|------|---------|
| Deploy latest code | `make deploy` |
| Trigger a backup | `make backup` |
| Restore last backup | `make restore` |
| Restore specific snapshot | `make restore TIMESTAMP=20240115_023001` |

### On the server directly

```bash
# List available backup snapshots
sudo myapp-restore --list

# Restore most recent snapshot
sudo myapp-restore --last

# Restore a specific snapshot
sudo myapp-restore --timestamp 20240115_023001

# Run a manual backup
sudo myapp-backup
```

(`myapp` is replaced with your `app_name`, which defaults to the basename of `app_dir`.)

## Deploy-on-push (optional)

Set `deploy_on_push: true` in `vars.yml` and re-run `make provision`. After provisioning, the output will display a webhook URL and instructions to configure it in GitHub (Settings → Webhooks).

## Project structure

```
├── ansible.cfg                  # Ansible configuration
├── Makefile                     # Convenience targets (provision, deploy, backup, restore)
├── requirements.yml             # Galaxy collection dependencies
├── inventory/
│   └── hosts.yml                # Server inventory
├── group_vars/all/
│   ├── vars.yml                 # Non-secret configuration
│   └── vault.yml                # Encrypted secrets (ansible-vault)
├── playbooks/
│   ├── provision.yml            # Full server setup (run once)
│   ├── deploy.yml               # Deploy latest code
│   ├── backup.yml               # Trigger backup
│   ├── restore.yml              # Restore snapshot
│   └── tasks/
│       └── deploy-steps.yml     # Shared deploy steps (used by provision + deploy)
└── roles/
    ├── common/                  # Base packages, unattended-upgrades
    ├── php/                     # PHP-FPM, OPcache, app pool
    ├── composer/                # Composer installation
    ├── nodejs/                  # Node.js + pnpm
    ├── mysql/                   # MySQL, database, user, hardening
    ├── valkey/                  # Valkey (Redis-compatible) config
    ├── nginx/                   # Nginx, HTTPS config, rate-limiting
    ├── certbot/                 # Let's Encrypt certificate
    ├── ufw/                     # Firewall rules
    ├── ssh_hardening/           # SSH hardening
    ├── fail2ban/                # Brute-force protection
    ├── supervisor/              # Queue workers + scheduler
    ├── logrotate/               # Log rotation
    ├── laravel_app/             # App user, deploy key, repo, .env, backup/restore scripts
    └── webhook/                 # Deploy-on-push webhook listener
```

## Secrets management

Secrets (database passwords, Redis password, webhook HMAC key) live exclusively in `group_vars/all/vault.yml`, encrypted with `ansible-vault` and never committed in plain text. On the server they are written to `/etc/<app_name>/secrets.env` (mode 640, root:app_user only).

To rotate a secret: update `vault.yml`, re-encrypt, and run `make provision` (idempotent).

## Backups

Daily snapshots run at 02:30 AM via cron. Each snapshot contains:
- Compressed MySQL dump (`.sql.gz`)
- Storage tarball (`storage/app` only, excludes logs/framework)
- Git commit reference for code rollback

`keep_backups` (default: 7) controls how many sets are retained. A pre-deploy backup is also taken automatically before each `make deploy`.

## Running individual roles

```bash
# Only (re-)configure PHP-FPM
ansible-playbook playbooks/provision.yml --tags php

# Only update Nginx config
ansible-playbook playbooks/provision.yml --tags nginx

# Only update fail2ban rules
ansible-playbook playbooks/provision.yml --tags fail2ban
```

Available tags: `common`, `php`, `composer`, `nodejs`, `mysql`, `valkey`, `nginx`, `certbot`/`tls`, `app`, `supervisor`, `fail2ban`, `ufw`, `ssh`, `logrotate`, `webhook`.

## Security posture

- SSH: key-only auth, password auth disabled, root login restricted, strong ciphers only
- Firewall: UFW default deny — only ports 22, 80, 443 open
- MySQL: localhost-only, no anonymous accounts, no remote root
- Valkey: localhost-only, password-required, dangerous commands disabled
- PHP-FPM: `open_basedir` restriction, dangerous functions disabled
- Nginx: HSTS, CSP, X-Frame-Options, rate-limiting on auth endpoints (5 req/min)
- Fail2ban: login brute-force, bot scanner, rate-limit violation, SSH brute-force jails
- Unattended-upgrades: automatic security patches with auto-reboot for kernel updates
- Secrets: ansible-vault encrypted at rest; mode 640 on server
