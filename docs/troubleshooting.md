# Troubleshooting log

Ploi + DigitalOcean rollout problems (never-completed deploys, 522s from stale DNS, a Supervisor crash-loop,
no scheduler, a superuser app login, a token in the deploy script) are in the
[setup guide's troubleshooting](guides/ploi-digitalocean-setup.md#troubleshooting-real-findings).

## 503 after deploy / first install never finished

The site returns 503 (often through Cloudflare) or Laravel's maintenance page
after a deploy. Usually the first deploy stopped before the app was installed.
Check, on the web server, as `ploi`:

| Check | Command | If it fails |
|---|---|---|
| Did the first install finish? | `ls <shared>/.first-install-done <app>/storage/installed` | Neither exists: the first install never completed. Read the last deploy log in Ploi → site → Deployments. It names the empty `.env` keys or the missing `install.env` |
| Is `install.env` needed? | `ls -l <shared>/install.env` | With `INSTALL_ENV_KEYS` set: create it as `KEY=value` lines, `chmod 600`, deploy again. It's deleted after a good install |
| Required `.env` keys set? | `grep -E '^(APP_KEY\|APP_URL\|DB_HOST\|DB_PASSWORD)=' <shared>/.env \| sed 's/=.*/=…/'` | Fill them in with Ploi's editor or `update-env-db.sh`, then deploy |
| Ploi's editor shows the real `.env`? | `ls -l /home/ploi/<site>/.env` | Not a symlink to `<shared>/.env` (when the app root differs from the site root): deploy once with the current script, or `ln -sfn <shared>/.env /home/ploi/<site>/.env` |
| Still in maintenance mode? | `ls <app>/storage/framework/down` | `php artisan up` |
| What did Laravel log? | `tail -n 100 <app>/storage/logs/laravel.log` | Fix the error shown (DB auth, missing extension, cache path) |
| Can the app reach the DB? | `src/shell/web/check-db-reach.sh --env <shared>/.env` | See the DB server's `doctor` |
| Are the daemons running? | `pgrep -af 'queue:work\|schedule:work'` | Add them in Ploi ([daemons.md](recipes/run-daemons.md)). Without them jobs and schedules never run, though pages still render |
| PHP-FPM / nginx up? | `systemctl status php*-fpm nginx`, `/var/log/nginx/error.log` | Restart from Ploi |

`<shared>` is `/home/ploi/<site>-shared`. `<app>` is the release (zero-downtime) or
`/home/ploi/<site>/<APP_SUBDIR>` (in-place).

## Log

Real problems hit while building the reference deployment, and the fix for each.

| Symptom | Cause | Fix |
|---|---|---|
| Ploi deploy fails with `main: unbound variable` | Ploi replaces `{BRANCH}`-style placeholders in the script text before bash runs, so `${BRANCH}` became `$main` | Never name variables after Ploi placeholders; use `DEPLOY_BRANCH` etc. ([deploy.md](tools/deploy-script.md#ploi-placeholder-caveat)) |
| PgBouncer logs a login every 5 seconds | The container healthcheck (`pg_isready ... -d pgbouncer`) | Expected; not an attack. Ignore or filter |
| A MySQL/MariaDB restore brought back old users / root passwords stopped matching `.env` | Full dumps included the `mysql` system schema | `backup` dumps user databases only, so restores never touch root/users. Recreate app users after a restore |
| Postgres restore hangs or fails on `DROP DATABASE` | PgBouncer held pooled connections to the database | `restore` stops PgBouncer first and starts it after; it also skips the bootstrap role's DROP/CREATE ROLE lines |
| Image build fails with apt `500 Internal Server Error` or `Could not connect to apt.postgresql.org:80` | Flaky mirror; plain-HTTP pgdg | The Dockerfile uses HTTPS for pgdg and `Acquire::Retries=5`; rerun |
| `verify` times out at `-- pgbouncer (via <ip>:6432)` (`verify exit=2`) | The check ran inside a container against the host's own private IP; ufw drops that hairpin traffic (source is a Docker bridge IP, not the VPC) | Fixed: `verify` reaches PgBouncer at `pgbouncer:5432` on the Docker network. Real clients on the VPC were never affected (test from the web server: `nc -zv <ip> 6432`) |
| A chain `reset && cron-install && env` stopped after verify | The `&&` chain stops at the first failing command (the verify timeout above) | Rerun the remaining commands after `verify` passes |
| Termius: `Authentication failed (publickey)` | Termius offered the right key but it is not in the server's `authorized_keys` for that user | Add the `.pub` key in Ploi for `ploi` ([ssh-access.md](recipes/set-up-ssh-access.md)) |
| `scp: stat local "/home/ploi/Downloads/..."`, `Could not resolve hostname <alias>`, or `ploi@<host>: Permission denied (publickey)` right after a login banner | Workstation commands run while logged into the server | Exit to the workstation, or use `src/shell/db/remote-run.sh` from there |
| `zsh: no such file or directory: db-alias` (bash: `db-alias: No such file or directory`) running `remote-run.sh` | A `<db-alias>`-style placeholder pasted literally; `<` and `>` are shell redirections, so the script never started | Use the real `user@ip` or alias, or set `SIWO_DB_SSH_HOST` in the root `.env` ([remote-run](tools/remote-run.md#troubleshooting)) |
| `sudo: a terminal is required to read the password` / `sudo: a password is required` from `remote-run.sh` | The login user's sudo needs a password and the session has no terminal | Run it in a terminal: remote-run probes `sudo -n true` and lets sudo ask once over `ssh -t`; never put the password on a command line ([sudo](tools/remote-run.md#sudo)) |
| `sudo` rejects the password | Wrong password (DB/Ploi-login password, or stray whitespace from copy-paste) | Use the sudo password from Ploi's provisioning email, type it, or `passwd ploi` from the DO web console |
| Login banner: `*** System restart required ***` | Kernel/security updates pending | Full upgrade and reboot ([security.md](security.md#updates-and-reboots)) before running the setup |
| apt: `N not upgraded` / `no longer required` | Held-back updates and unused dependencies | `sudo apt-get update && sudo apt-get full-upgrade -y && sudo apt-get autoremove --purge -y && sudo apt-get autoclean` |
| A `10.10.x.x` address in the banner instead of the VPC IP | DO's anchor IP on `eth0` | Normal. The VPC IP is on `eth1` |
| Caddy: certificate not issued, 502, `File not found.` | DNS/ports, container network, or `php_fastcgi` root | See [web-server-caddy.md](tools/caddy-stack.md#troubleshooting) |
