# Server tools: `workbench server ...` and `workbench web diagnose`

Shell tools that run **on a droplet** (or from your workstation with `--host`, which copies the tool plus
`src/shell/lib/common.sh` over ssh, runs it with `sudo`, and removes the copy). They all follow the same rules:

| Rule | How |
|---|---|
| Plan first | Every run prints what it found and what it would change. `--dry-run` stops there |
| Confirm | `--yes`, or type `yes`. Production fixes need the **site domain typed**; `--yes` is not enough |
| Lock | One run per tool at a time (`/run/lock/vsw-<tool>.lock`) |
| Audit | `/var/log/vps-server-workbench/audit.log`: who, what, outcome. Values are never logged |
| Backups | Any file replaced is copied to `<file>.bak.<timestamp>` (mode 600) first; writes are atomic. In `/etc/apt/*.d` the copy is `<file>.<timestamp>.bak`, which apt skips quietly (`harden` renames older `.bak.<timestamp>` copies there) |
| Re-runnable | Items already in place report `ok` and are skipped |

Exit codes: `0` fine, `1` a failure was found or a step failed, `2` usage error, `3` not confirmed.

## `server init`: first boot

```bash
bin/workbench server init --host db-1 --role db                 # plan
bin/workbench server init --host db-1 --role db --yes           # apply (copies init.sh + harden.sh)
bin/workbench server init --host web-1 --role web --yes         # Ploi web server: timezone, swap, base tools, harden
```

| Item | What it does | Why |
|---|---|---|
| `timezone` | `timedatectl set-timezone UTC` (`--timezone Area/City`) | Logs, cron and backups line up across servers |
| `swap` | `/swapfile` (`--swap 2G`, `0` = never) when there is no swap, `/etc/fstab` entry; db role: `vm.swappiness=10` | A small droplet with no swap gets OOM-killed (usually the DB) on a spike |
| `packages` | `ca-certificates curl gnupg jq unzip htop` | What the other tools and you expect to find |
| `docker` | db role only, never on a Ploi server: Docker's apt repo (`signed-by` keyring), `docker-ce`, compose and buildx plugins; `/etc/docker/daemon.json` with 10 MB x 3 log rotation and `live-restore` (an existing, different file is left alone with a warning) | The DB manager runs its stack with compose; unrotated logs fill disks |
| `harden` | runs `server harden --role <role>` (plus `--firewall` when asked and not Ploi) | One baseline everywhere |

Web servers are provisioned by **Ploi** (PHP, nginx, firewall); `init --role web` without Ploi warns and
does only the generic items.

## `server inventory`

```bash
bin/workbench server inventory --host db-1 --pull --client acme   # -> local/acme/inventory/db-1/ (gitignored)
bin/workbench server inventory --json                             # on the server, to stdout
bin/workbench server inventory --host db-1 --install-cron --yes   # daily 05:17 into /var/lib/vps-server-workbench/inventory
```

Records OS, kernel, timezone, pending upgrades and reboot, CPU/RAM/swap/disk, IPv4 addresses, listening TCP
sockets, Ploi sites (names only), PHP/nginx/Docker/compose/DB-manager versions, containers (image + state),
service states and the security baseline (ssh drop-in, ufw, fail2ban, key count). It **never reads `.env`
values, keys or passwords**.

The canonical form is a sorted `key<TAB>value` file (`inventory.txt`) so two runs diff cleanly;
`inventory.json` and `inventory.md` are generated from it. Each `--pull` or `--out` run keeps a dated copy
and writes `changes-<timestamp>.diff` when something changed (a new listening port, a container image,
a reboot pending). `--pull` runs without a tty, so it needs passwordless `sudo` for the ssh user.
Inventories contain IPs and hostnames: they stay under `local/<client>/` or `inventory/`, both gitignored.

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
| `dockergroup` | Reports non-root members of the `docker` group as a warning. `--fix-docker-group` removes them (`gpasswd -d`, after the usual confirmation); `--docker-allow a,b` keeps intended users | The `docker` group is root without a password: `docker run -v /:/host` owns the server, so a leaked deploy key becomes root. Reporting by default keeps `harden --yes` from breaking a workflow that relies on it |
| `firewall` | Only with `--firewall` (`--allow 80,443`): ufw allows OpenSSH first, then default-deny inbound. **Skipped on Ploi servers** (Ploi owns ufw) | Defence in depth behind the DO cloud firewall |

**Lockout guard:** the `ssh` item is refused when neither root nor any `/home/*` user has an `authorized_keys`
entry. After applying, keep the session open and test a new login. If you do get locked out, see
[the lockout recipe](../recipes/recover-ssh-lockout.md).

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
[lessons learned](../lessons-learned.md#networking).

## Testing

`tests/shell/smoke-server.sh` (part of `make test`) runs every tool against a fake root (`VSW_SYSROOT`)
with stub commands on `PATH`. `tests/shell/server-it.sh` (part of `make it`) runs `init`, `harden`,
`inventory`, `update --dry-run` and `env` for real as root in a throwaway Ubuntu 26.04 container (`SERVER_IT_IMAGE=ubuntu:24.04` for the previous LTS): real apt,
real `sshd -t`/`sshd -T` (including the rollback of a broken drop-in), real audit log and cron install.
Swap, the Docker install and `--host` are covered by the offline stubs only.
