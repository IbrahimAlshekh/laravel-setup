# Laravel Production Server Setup

A two-script toolkit that provisions a hardened Ubuntu server for Laravel and keeps it deployed. One script initialises the server; a second script deploys your application — manually or automatically on every git push.

---

## What it installs

| Component | Details |
|-----------|---------|
| **PHP** | Configurable version (default 8.4), FPM pool with dedicated system user, OPcache, `open_basedir`, dangerous functions disabled |
| **MySQL 8** | Bound to localhost only, anonymous accounts removed, root password locked away in the secrets file |
| **Valkey** | Password-protected, bound to localhost only, dangerous commands (`FLUSHALL`, `CONFIG`, etc.) disabled. Drop-in Redis replacement (same protocol — Laravel's `REDIS_*` config works unchanged) |
| **Nginx** | TLS 1.2/1.3 via Let's Encrypt (auto-renewed), HSTS, security headers, rate-limiting on auth endpoints, hidden-file blocking |
| **Supervisor** | Laravel queue workers (`queue:work redis`) + scheduler (`schedule:work`), both run as the app user |
| **Fail2ban** | Laravel admin brute-force, Nginx bot scanner, rate-limit violations, SSH brute-force |
| **UFW** | Default deny; allows only SSH, HTTP, HTTPS |
| **SSH hardening** | Password auth disabled, root login restricted, strong ciphers/MACs only |
| **Unattended-upgrades** | Security patches applied automatically |
| **Backups** | DB dump + storage tarball + git ref — before every deploy and daily at 02:30; 7-day rolling retention |
| **Deploy-on-push** | Optional: GitHub webhook with HMAC verification; deploys on push to the configured branch |

---

## Prerequisites

- Fresh **Ubuntu 22.04 or 24.04** server
- **Root access** (SSH as root, or a user with `sudo su`)
- **DNS** pointing `example.com` and `www.example.com` to the server's IP
- A **GitHub repository** containing your Laravel application

> **Before running setup:** make sure you have at least one SSH public key authorised for the root user (or a sudoer). The script disables password authentication at the end — if you have no key set up, you will be locked out.

---

## Quickstart

```bash
# 1. Clone this repo onto the server (as root)
git clone https://github.com/IbrahimAlshekh/laravel-setup.git /opt/laravel-setup
cd /opt/laravel-setup

# 2. Fill in your 9 values
cp .env.deploy.example .env.deploy
nano .env.deploy          # see the comments in the file

# 3. Run the one-time setup (~5–10 minutes)
sudo bash setup.sh
```

During setup you will be prompted once to add a deploy key to GitHub, then the script continues unattended.

---

## The 9 configuration values (`.env.deploy`)

| Variable | Example | Description |
|----------|---------|-------------|
| `DOMAIN` | `example.com` | Your domain — no `www`, no protocol |
| `CERTBOT_EMAIL` | `admin@example.com` | Let's Encrypt contact email |
| `REPO_URL` | `git@github.com:org/repo.git` | SSH URL of your Laravel repository |
| `REPO_BRANCH` | `main` | Branch to deploy |
| `APP_DIR` | `/var/www/myapp` | Where the application lives on the server |
| `BACKUP_DIR` | `/var/backups/myapp` | Where backups are stored |
| `KEEP_BACKUPS` | `7` | How many daily backup sets to keep |
| `PHP_VERSION` | `8.4` | PHP version to install |
| `DEPLOY_ON_PUSH` | `false` | `true` to enable GitHub webhook auto-deploy |

Everything else (DB password, Valkey password, `APP_KEY`, webhook secret) is **generated automatically** and never shown on screen. It is stored in:

```
/etc/<app-name>/secrets.env   (mode 600, root only)
```

---

## Day-2 deployments

**Manual (default):**
```bash
sudo bash /opt/laravel-setup/deploy.sh
```

**Automatic on push** (`DEPLOY_ON_PUSH=true`):

After `setup.sh` completes, it prints:
- The GitHub webhook URL to register
- Where to find the HMAC secret

In your GitHub repository: **Settings → Webhooks → Add webhook**

| Field | Value |
|-------|-------|
| Payload URL | `https://example.com/__deploy/<random-path>` |
| Content type | `application/json` |
| Secret | *(from `/etc/<app>/secrets.env` → `WEBHOOK_SECRET`)* |
| Which events | Just the push event |

Every push to `REPO_BRANCH` will automatically trigger a full deploy.

### What a deployment does

1. Creates a pre-deploy backup snapshot
2. Puts the app into maintenance mode
3. `git reset --hard origin/<branch>`
4. `composer install --no-dev`
5. `pnpm install && pnpm build` (or npm, if no pnpm lockfile)
6. `php artisan migrate --force`
7. `php artisan optimize:clear` → `config:cache route:cache view:cache event:cache`
8. Fixes permissions on `storage/` and `bootstrap/cache/`
9. Restarts PHP-FPM (full restart — required for OPcache) and Supervisor workers
10. Lifts maintenance mode
11. Runs a health check (`https://example.com/up`)

On failure: maintenance mode is lifted automatically; a rollback can be triggered with `AUTO_ROLLBACK=true`.

---

## Backups

Backups run in two situations:

1. **Before every deploy** — a snapshot is always created first
2. **Daily at 02:30** — via `/etc/cron.d/<app>-backup`

Each snapshot contains:
- `db_YYYYMMDD_HHMMSS.sql.gz` — MySQL dump (or SQLite copy)
- `storage_YYYYMMDD_HHMMSS.tar.gz` — uploaded files
- `git_YYYYMMDD_HHMMSS.ref` — the deployed git SHA (for code rollback)

Snapshots are stored in `BACKUP_DIR` (mode 700, root only) and rotated to keep the last `KEEP_BACKUPS` sets of each type.

---

## Rollback

List available snapshots:
```bash
sudo bash /opt/laravel-setup/lib/restore.sh --list
```

Restore the most recent snapshot:
```bash
sudo bash /opt/laravel-setup/lib/restore.sh --last
```

Restore a specific snapshot:
```bash
sudo bash /opt/laravel-setup/lib/restore.sh --timestamp 20240115_023001
```

Restore puts the app into maintenance mode, restores the DB dump, re-extracts the storage archive, checks out the saved git ref, rebuilds caches, restarts services, and lifts maintenance mode.

> **Note:** restoring a DB dump is the correct rollback for schema migrations. The restore script does not run `migrate:rollback` — it replaces the database entirely with the dump taken before the failed deploy.

---

## Secrets

All generated secrets are stored in `/etc/<app-name>/secrets.env` (mode 600, readable only by root).

To view:
```bash
sudo cat /etc/<app-name>/secrets.env
```

To rotate a secret (e.g. Valkey password):
1. Edit the secrets file: `sudo nano /etc/<app-name>/secrets.env`
2. Update `REDIS_PASS=<new-value>` in the file
3. Re-render the Valkey config: `sudo bash /opt/laravel-setup/setup.sh` (idempotent — only changes what differs)
4. Update `REDIS_PASSWORD=<new-value>` in `$APP_DIR/.env`
5. `sudo bash /opt/laravel-setup/deploy.sh`

---

## Security posture

### What is hardened

- SSH key-only auth; root login restricted; weak ciphers disabled
- UFW: only ports 22, 80, 443 open
- MySQL: localhost-only, no anonymous accounts, no test database
- Valkey: localhost-only, password-required, dangerous commands disabled
- PHP-FPM: `open_basedir` restricts filesystem access; execution functions disabled
- Nginx: HSTS, CSP upgrade, X-Frame-Options, nosniff, rate-limiting on login endpoints
- Fail2ban: protects SSH, Nginx, and Laravel admin login
- Unattended-upgrades: OS security patches applied automatically
- All generated passwords: 32-char cryptographically random strings
- Secrets file: mode 600, root-only — never echoed to stdout
- Deploy user owns the code; the FPM pool can only read it (except `storage/` and `bootstrap/cache/`)

### What is not included (consider adding for high-security environments)

- **WAF** (ModSecurity, Cloudflare) — not installed
- **IDS/IPS** (Suricata, Snort) — not installed
- **Offsite backup** (S3, Backblaze) — backups are local only; copy them offsite
- **Log aggregation** (Loki, Datadog) — logs are on-disk only
- **SELinux/AppArmor profiles** — not configured
- **2FA for SSH** — not configured

---

## Troubleshooting

### Where are the logs?

| What | Path |
|------|------|
| Deploy log | `$APP_DIR/storage/logs/deploy.log` |
| Laravel app log | `$APP_DIR/storage/logs/laravel.log` |
| Queue workers | `$APP_DIR/storage/logs/queue.log` |
| Scheduler | `$APP_DIR/storage/logs/scheduler.log` |
| Nginx access | `/var/log/nginx/<domain>.access.log` |
| Nginx error | `/var/log/nginx/<domain>.error.log` |
| PHP-FPM error | `/var/log/php/<app>-fpm-error.log` |
| PHP-FPM slow | `/var/log/php/<app>-slow.log` |
| Daily backup | `/var/log/<app>-backup.log` |

### Services

```bash
# Check all relevant services
systemctl status nginx php8.4-fpm mysql valkey supervisor fail2ban ufw

# Queue workers
supervisorctl status

# Fail2ban bans
fail2ban-client status
fail2ban-client status sshd
```

### Re-running setup safely

`setup.sh` is idempotent. Re-running it on an already-configured server will:
- Skip package installation if already installed
- Preserve existing secrets (never regenerates)
- Skip repository clone if `APP_DIR/.git` exists
- Skip `.env` creation if it already exists
- Update config files and reload services

To re-provision from scratch, back up `$APP_DIR/.env` and `/etc/<app>/secrets.env`, then restore them after running setup.sh fresh.

### Disabling the webhook

```bash
sudo systemctl disable --now webhook-<app>
sudo rm /etc/nginx/snippets/<app>-webhook.conf
# Edit /etc/nginx/sites-available/<app> to remove the include line
sudo nginx -t && sudo systemctl reload nginx
```

---

## Directory structure

```
laravel-setup/
├── setup.sh                    # One-time server provisioning
├── deploy.sh                   # Repeatable deployment
├── .env.deploy.example         # Configuration template (copy → .env.deploy)
├── lib/
│   ├── common.sh               # Shared helpers, env loader
│   ├── secrets.sh              # Secret generation and storage
│   ├── backup.sh               # Backup (called by deploy + cron)
│   ├── restore.sh              # Restore a backup snapshot
│   └── healthcheck.sh          # Post-deploy health verification
└── config/
    ├── nginx.conf.tmpl
    ├── nginx-rate-limit.conf.tmpl
    ├── nginx-webhook.conf.tmpl
    ├── php-fpm-pool.conf.tmpl
    ├── opcache-prod.ini
    ├── supervisor.conf.tmpl
    ├── valkey-app.conf.tmpl
    ├── sshd-hardening.conf
    ├── unattended-upgrades.conf
    ├── logrotate.conf.tmpl
    ├── sudoers-deploy.tmpl
    ├── backup.cron.tmpl
    ├── webhook.hook.json.tmpl
    ├── webhook.service.tmpl
    └── fail2ban/
        ├── jail-app.conf.tmpl
        └── filter-app.conf.tmpl
```

---

## License

MIT
