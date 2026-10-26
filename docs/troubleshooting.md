# Troubleshooting log

Real problems hit while building the reference deployment, and the fix for each.

| Symptom | Cause | Fix |
|---|---|---|
| Ploi deploy fails with `main: unbound variable` | Ploi replaces `{BRANCH}`-style placeholders in the script text before bash runs, so `${BRANCH}` became `$main` | Never name variables after Ploi placeholders; use `DEPLOY_BRANCH` etc. ([deploy.md](deploy.md#ploi-placeholder-caveat)) |
| PgBouncer logs a login every 5 seconds | The container healthcheck (`pg_isready ... -d pgbouncer`) | Expected; not an attack. Ignore or filter |
| A MySQL/MariaDB restore brought back old users / root passwords stopped matching `.env` | Full dumps included the `mysql` system schema | `backup` dumps user databases only, so restores never touch root/users. Recreate app users after a restore |
| Postgres restore hangs or fails on `DROP DATABASE` | PgBouncer held pooled connections to the database | `restore` stops PgBouncer first and starts it after; it also skips the bootstrap role's DROP/CREATE ROLE lines |
| Image build fails with apt `500 Internal Server Error` or `Could not connect to apt.postgresql.org:80` | Flaky mirror; plain-HTTP pgdg | The Dockerfile uses HTTPS for pgdg and `Acquire::Retries=5`; rerun |
| `verify` times out at `-- pgbouncer (via <ip>:6432)` (`verify exit=2`) | The check ran inside a container against the host's own private IP; ufw drops that hairpin traffic (source is a Docker bridge IP, not the VPC) | Fixed: `verify` reaches PgBouncer at `pgbouncer:5432` on the Docker network. Real clients on the VPC were never affected (test from the web server: `nc -zv <ip> 6432`) |
| A chain `reset && cron-install && env` stopped after verify | The `&&` chain stops at the first failing command (the verify timeout above) | Rerun the remaining commands after `verify` passes |
| Termius: `Authentication failed (publickey)` | Termius offered the right key but it is not in the server's `authorized_keys` for that user | Add the `.pub` key in Ploi for `ploi` ([ssh-access.md](ssh-access.md)) |
| `scp: stat local "/home/ploi/Downloads/..."`, `Could not resolve hostname <alias>`, or `ploi@<host>: Permission denied (publickey)` right after a login banner | Workstation commands run while logged into the server | Exit to the workstation, or use `scripts/db/remote-run.sh` from there |
| `sudo` rejects the password | Wrong password (DB/Ploi-login password, or stray whitespace from copy-paste) | Use the sudo password from Ploi's provisioning email, type it, or `passwd ploi` from the DO web console |
| Login banner: `*** System restart required ***` | Kernel/security updates pending | `sudo reboot` before running the setup |
| A `10.10.x.x` address in the banner instead of the VPC IP | DO's anchor IP on `eth0` | Normal. The VPC IP is on `eth1` |
