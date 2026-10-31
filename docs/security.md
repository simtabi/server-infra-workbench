# Security and operations

## Firewall and Docker

How each client reaches the databases (SSH tunnels, the loopback-only Adminer UI, VPC-only ufw rules) is in
[connections.md](recipes/connect-to-databases.md).

- **Docker-published ports bypass ufw.** Docker writes its own iptables rules
  ahead of ufw's, so `ufw deny 5432` does **not** block a port that a container
  publishes on `0.0.0.0`. The manager therefore publishes every DB port on the
  private IP only (`PRIVATE_IP:5432:5432`); the ufw rules for `VPC_CIDR` are a
  second layer. Never change a compose file to `"5432:5432"`.
- Check it: `docker-db-server-manager.sh doctor` fails if any DB port listens on
  `0.0.0.0`/`[::]` or on a public address. By hand: `ss -tlnH | awk '{print $4}'`.
- ufw should be `default deny incoming` with `22` (and on the web server `80`,
  `443`) open. `doctor` checks the default policy (needs root).
- DigitalOcean cloud firewalls are an extra layer worth having: allow 22 from
  your IPs, 80/443 to the web droplet, and nothing public to the DB droplet.

## Encryption on the private network

Traffic between the web and DB droplets uses the DigitalOcean VPC without TLS.
For options, see [status.md](status.md#private-network-encryption).

## Updates and reboots

```sh
sudo apt-get install -y unattended-upgrades && sudo dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl is-active unattended-upgrades
ls /var/run/reboot-required 2>/dev/null && cat /var/run/reboot-required.pkgs   # reboot when present
```

Bring a server fully up to date (installs held-back packages, removes unused
dependencies, cleans the package cache, then reboots):

```sh
sudo apt-get update && sudo apt-get full-upgrade -y && sudo apt-get autoremove --purge -y && sudo apt-get autoclean && sudo reboot
```

`full-upgrade` installs the updates plain `upgrade` keeps back ("N not upgraded"),
and `autoremove` drops the "automatically installed and no longer required"
packages apt lists. The reboot drops your SSH session; reconnect after a minute.

Reboot the web server in a quiet window; on the DB server the containers come
back by themselves (`restart: unless-stopped`), check with `verify` afterwards.
fail2ban (Ploi installs it) protects SSH: `sudo fail2ban-client status sshd`.

## Secrets on disk

| File | Should be |
|---|---|
| `/opt/db/.env` (DB passwords) | `600 root` |
| `/etc/docker-db-server-manager.conf` (no secrets) | `600 root` |
| `/opt/db/backups` | `700 root` |
| `/home/ploi/<site>-shared/.env` | `600 ploi` (the deploy script enforces it) |
| `<shared>/.env.bak.*` from `update-env-db.sh` | `600`; only the newest `KEEP_BACKUPS` (5) kept |
| `<shared>/install.env` | deleted after the first install (`shred`) |

Find stray copies: `find /home/ploi -maxdepth 3 -name '.env*' -printf '%m %p\n'`.

## Secrets in the repository: generated, never written down

**Rule:** a password, token or key is generated when it is needed (`openssl rand -hex 24`,
`random_bytes()`, `secrets.token_urlsafe()`) or read from a 600 file or `${VAR:?}`. It is never a
literal, not even a test value. Docs show `<generated>` or `$(openssl rand -base64 24)`.

**Why:** scanners (GitGuardian, gitleaks) cannot tell a test password from a real one, and neither can a
reviewer at a glance. Every literal is an incident someone has to triage, and a "test" value has a way of
being reused on a real box. Generated values also make tests prove the code handles *any* value, not one.

| Check | Where |
|---|---|
| `tests/security/no-hardcoded-secrets.py` | tracked files: `KEY=literal`, `--password <literal>`, URLs with a user and a password before the host (even when both are variables), `mysql -p...`; never prints values |
| `gitleaks` with [`.gitleaks.toml`](../.gitleaks.toml) | default rules + a generic-password rule, whole history (`--log-opts=--all`) |
| `make secrets-check` | both of the above; part of `make ci` and the pre-push hook in `.pre-commit-config.yaml` |

A public vendor default that the code *refuses* (for example `minioadmin`) may stay in a test with an
inline `vsw-secrets: ignore` and a reason. Nothing else qualifies.

Lesson (2026-10): GitGuardian flagged four "Generic Password" findings in commits `962d644` and `6f7b1d5`.
All were test fixtures or an env-reference DSN, never real credentials, so no rotation was needed and
history was not rewritten. The fixtures are now generated per run, the DSN is built by `monitor.sh`
into `secrets.env`, and the old commits are listed in `.gitleaks.toml` so the history scan stays green.
A follow-up GitGuardian "PostgreSQL Credentials" alert on `222b630` matched a DSN made only of variables
(a postgres URL whose user and password parts were both shell substitutions). The shape alone trips scanners, so no tracked file may contain a URL with
a user and password before the host: the pgbouncer exporter now gets a libpq `key=value` string built into
`secrets.env`, and docs use `postgres://USER@HOST/db` with the password in `PGPASSFILE` or a `<generated>`
placeholder. The scanner flags the shape even when every part is a variable.

## Logs

| What | Where |
|---|---|
| Nightly DB backup | `/var/log/docker-db-server-backup.log` (logrotate weekly, 8 kept) |
| DB containers | `docker-db-server-manager.sh logs [postgres\|pgbouncer\|mysql\|mariadb]` |
| Deploys | Ploi → site → Deployments |
| Laravel | `<shared>/storage/logs/laravel.log` (or `<site>/storage/logs` on in-place sites) |
| Daemons | Ploi → server → Daemons → log, or `/home/ploi/.ploi/*.log` |
| nginx / PHP-FPM | `/var/log/nginx/`, `/var/log/php*-fpm.log` |
| SSH / fail2ban | `journalctl -u ssh`, `/var/log/fail2ban.log` |

## Monitoring (not built in)

Setup commands: [connections.md](recipes/connect-to-databases.md#8-monitoring).

This is ranked gap 3 in [status.md](status.md#monitoring).


Nothing here pages you. Cheap options: Ploi's server monitoring and email alerts,
DigitalOcean monitoring alerts (CPU, disk, memory), an uptime check on
`https://<site>/up` (UptimeRobot, Better Stack), and a cron that runs
`docker-db-server-manager.sh doctor` and mails on a non-zero exit, e.g.
`30 6 * * * root /root/docker-db-server-manager.sh doctor >/dev/null || echo "doctor failed on $(hostname)" | mail -s doctor you@example.com`.
