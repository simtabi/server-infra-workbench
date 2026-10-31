# Server tools: `workbench server ...` and `workbench web diagnose`

Shell tools that run **on a droplet** (or from your workstation with `--host`, which copies the tool plus
`src/shell/lib/common.sh` over ssh, runs it with `sudo`, and removes the copy). They all follow the same rules:

| Rule | How |
|---|---|
| Plan first | Every run prints what it found and what it would change. `--dry-run` stops there |
| Confirm | `--yes`, or type `yes`. Production fixes need the **site domain typed**; `--yes` is not enough |
| Lock | One run per tool at a time (`/run/lock/vsw-<tool>.lock`) |
| Audit | `/var/log/vps-server-workbench/audit.log`: who, what, outcome. Values are never logged |
| Backups | Any file replaced is copied to `<file>.bak.<timestamp>` (mode 600) first; writes are atomic |
| Re-runnable | Items already in place report `ok` and are skipped |

Exit codes: `0` fine, `1` a failure was found or a step failed, `2` usage error, `3` not confirmed.

## `server harden`

```bash
bin/workbench server harden --host db-1                 # plan only
bin/workbench server harden --host db-1 --yes           # apply
bin/workbench server harden --host web-1 --role web --check   # exit 1 if anything would change (cron/CI)
```

| Item | What it does | Why |
|---|---|---|
| `ssh` | `/etc/ssh/sshd_config.d/10-workbench.conf`: passwords and keyboard-interactive off, root by key only (`--root-login no` for none), `MaxAuthTries 3`, no X11/agent forwarding. Validated with `sshd -t`; rolled back if that fails; then `systemctl reload ssh` | Password logins are what bots brute-force |
| `updates` | `unattended-upgrades` with security updates daily, **no automatic reboot** | Fixes land without anyone logging in; reboots belong to `server update` |
| `fail2ban` | sshd jail: 5 failures in 10 min, 1 h ban, systemd backend | Fewer brute-force attempts and less log noise |
| `sysctl` | `/etc/sysctl.d/90-workbench.conf`: syncookies, rp_filter, no redirects/source routing, `kptr_restrict`, `dmesg_restrict` | Drops spoofed and redirected packets |
| `journald` | Cap at 500 MB, one month | An uncapped journal can fill a small disk and stop the DB |
| `firewall` | Only with `--firewall` (`--allow 80,443`): ufw allows OpenSSH first, then default-deny inbound. **Skipped on Ploi servers** (Ploi owns ufw) | Defence in depth behind the DO cloud firewall |

**Lockout guard:** the `ssh` item is refused when neither root nor any `/home/*` user has an `authorized_keys`
entry. After applying, keep the session open and test a new login. If you do get locked out, see
the lockout recipe (LOCKOUT_LINK).

Docker-published ports bypass ufw (Docker writes its own iptables rules). `harden` warns when a container
publishes on `0.0.0.0`. Bind DB ports to the private IP (the manager does) and use a DO cloud firewall
(`workbench do firewall-apply db`).

## `server update --reboot-window`

```bash
bin/workbench server update --host db-1                                   # plan: what is upgradable, reboot pending?
bin/workbench server update --host db-1 --yes --reboot-window 02:00-04:00 # upgrade; reboot inside the window
bin/workbench server update --host db-1 --yes --no-reboot --backup-first  # manager backup, upgrade, never reboot
```

- Reboots only when `/var/run/reboot-required` exists. Inside the window: in 1 minute. Outside: scheduled
  for the window's start (`shutdown -r HH:MM`; cancel with `shutdown -c`). Windows can cross midnight
  (`23:30-01:00`). Times are the **server's** clock (DigitalOcean droplets default to UTC).
- Docker packages restart every container, so with containers running they are **held for this run**
  (and released afterwards; holds you set yourself are left alone). Upgrade Docker deliberately with
  `--allow-docker` in a maintenance window.
- `--security-only` runs `unattended-upgrade`; `--full` uses `dist-upgrade`.
- `--backup-first` runs `/root/docker-db-server-manager.sh backup` and stops if it fails.

## `web diagnose`

```bash
bin/workbench web diagnose --host web-1 --site app.example.com              # read-only
bin/workbench web diagnose --host web-1 --site app.example.com --fix --dry-run
bin/workbench web diagnose --host web-1 --site app.example.com --env prd --fix   # asks you to type app.example.com
```

Checks (the `.env` is read but no value is ever printed): site dir and `artisan`; `.env` exists and is
mode 600; `APP_ENV` matches `--env`; `APP_DEBUG` off outside dev; `APP_KEY` set; `APP_URL` https on prd;
`storage` and `bootstrap/cache` owned by and writable for the site user; `public/storage` link; `.env`
newer than the config cache; DB and Redis reachable over TCP; DB host is a private address and the DB user
is not a superuser; a queue worker when `QUEUE_CONNECTION` is not `sync`; `schedule:run` in the crontab;
`nginx -t`; php-fpm running; disk use; recent `ERROR` lines and size of `laravel.log`; a local HTTPS request
and the certificate's days left.

`--fix` applies only safe, reversible fixes: `.env` to 600, `APP_DEBUG=false` (backup first), storage
permissions, `storage:link`, rebuild the config cache. It never generates `APP_KEY` (rotating it makes
encrypted data unreadable), never edits DB settings and never restarts services.

The DB-unreachable hint lists the usual causes: the public instead of the private IP, PgBouncer (6432) vs
Postgres (5432), the DO cloud firewall or ufw, or the DB containers being down. See
lessons learned (LESSONS_LINK).

## Testing

`tests/shell/smoke-server.sh` (part of `make test`) runs every tool against a fake root (`VSW_SYSROOT`)
with stub commands on `PATH`.
