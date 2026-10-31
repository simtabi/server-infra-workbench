# Live rollout runbook

Everything in this repo is tested offline and in containers, but these tasks have **never been run on a real
server**. This is the one ordered, copy-paste path through them. Run it from your workstation, top to bottom,
one step at a time; every write step has a dry run first and a verify after.

**Why one runbook:** the steps depend on each other (a snapshot before the upgrade, the upgrade before the
cron jobs, off-site before PITR, the network before the web side). Doing them out of order is the most likely
way to lose data or lock yourself out, so the order is the point.

## Placeholders

Set these in your shell first. Real values live in your gitignored `local/<client>/`, never in this repo.

```bash
DB=<db-ssh-alias>            # e.g. the alias from local/<client>/ssh-hosts.sh
WEB=<web-ssh-alias>
DB_IP=<db-private-ip>        # the DB droplet's VPC address (10.x)
DB_DROPLET=<db-droplet-id>
WEB_DROPLET=<web-droplet-id>
VPC=<vpc-id-or-cidr>
CONF=local/<client>/db-server.conf
ALERT_EMAIL=<you@example.com>
```

## Before you start

- [ ] `make ci` passes on your workstation and `bin/workbench credentials` shows the DO token.
- [ ] `ssh $DB true` and `ssh $WEB true` work, and you have a second session open on each (lockout insurance:
      [recover-ssh-lockout](../recipes/recover-ssh-lockout.md)).
- [ ] A quiet window: the upgrade restarts Postgres and PgBouncer (seconds, but connections drop).

## The 11 tasks

| # | Task | Run | Verify | Roll back |
|---|---|---|---|---|
| 1 | Snapshot the DB droplet | `bin/workbench do snapshot $DB_DROPLET --name pre-rollout --dry-run`, then without `--dry-run` and with `--wait` | `bin/workbench do snapshots $DB_DROPLET` lists it | nothing to undo |
| 2 | Roll out the manager upgrade (role split, PgBouncer `auth_query`, image retag) | `src/shell/db/remote-run.sh --host $DB --expect-ip $DB_IP --config $CONF -- upgrade --dry-run --snapshot-taken`, read the plan, then the same with `upgrade --snapshot-taken` | the upgrade ends with `verify` and `doctor` green | the upgrade's own savepoint rollback; worst case restore the snapshot ([roll-out](../recipes/roll-out-a-manager-upgrade.md)) |
| 3 | Health and credentials | `src/shell/db/remote-run.sh --host $DB --expect-ip $DB_IP --no-upload -- verify, doctor, env` | no `PROBLEM` lines; `env` prints the DB_* block (store it in Ploi, not in git) | - |
| 4 | Harden the DB server (incl. `ploi` out of `docker`) | `bin/workbench server harden --host $DB --role db`, read the plan, then add `--yes`; then `--only dockergroup --fix-docker-group` | `bin/workbench server harden --host $DB --role db --check` exits 0 | each change keeps a `.bak.*`; `sshd -t` failure rolls back by itself |
| 5 | Harden the web server | `bin/workbench server harden --host $WEB --role web` then `--yes` (firewall is left to Ploi) | `--check` exits 0 | as above |
| 6 | Private network | same region: `bin/workbench web check-db-reach --remote $WEB $DB_IP`; different regions: `bin/workbench net wireguard setup --host $DB --peer $WEB --dry-run`, then `--yes` | every DB port `open` from the web server; `net wireguard status --host $DB` shows a recent handshake | `net wireguard remove --host $DB --yes` |
| 7 | DO cloud firewall in front of the DB | `bin/workbench do firewall-apply db --vpc $VPC --droplet $DB_DROPLET --ssh-from <your-ip>/32 --dry-run`, then without `--dry-run` | `bin/workbench do firewalls` shows `WORLD-OPEN` empty for it; step 6 still passes | `bin/workbench do firewall-delete <id> --force` |
| 8 | Off-site backups | set `OFFSITE_*` in `$CONF`, re-run task 3 with `--config $CONF -- backup, offsite verify` | `offsite list` shows today's backup with a matching checksum | unset `OFFSITE_*` |
| 9 | Scheduled jobs and restore test | `src/shell/db/remote-run.sh --host $DB --expect-ip $DB_IP --no-upload -- cron-install, restore-test` | `restore-test` passes; `doctor` no longer warns about stale backups or restore tests | `cron-remove` |
| 10 | Point-in-time recovery (if `PITR=pgbackrest`) | `-- pitr setup, pitr backup full, pitr status` | `pitr status` shows a full backup and WAL archiving `ok` | set `PITR=off` and `upgrade` |
| 11 | Alerts and uptime | `bin/workbench do alerts standard --email $ALERT_EMAIL --droplet $DB_DROPLET,$WEB_DROPLET --dry-run`, then without; `bin/workbench do uptime check-create app https://<app-domain>/up`; set `HEALTHCHECK_URL` in `$CONF` | `bin/workbench do alerts list`; a test alert arrives (`doctor --alert` hourly) | `do alerts delete <uuid> --force` |

After task 11, deploy the web app with its new `DB_*` values (`bin/workbench env check --env <env>`, then a Ploi
deploy) and run `bin/workbench web check-db-reach --env <path-to-.env>` on the web server.

## Optional tasks (manager 1.5.0 and monitoring)

Do these after the 11 tasks, one per window. Each has a dry run and its own rollback.

| # | Task | Run | Verify | Roll back |
|---|---|---|---|---|
| 12 | Neutral Postgres image tag | remove `PG_IMAGE` from `$CONF`, then task 2 again ([recipe](../recipes/retag-postgres-image.md)) | `upgrade` prints `retired old image tag`; `docker images` shows `vsw/postgres` | the upgrade's savepoint re-tags the old image |
| 13 | TLS `verify-full` | `TLS_MODE=verify-full` in `$CONF`, task 2 again, then `-- tls-ca --out /tmp/vsw-db-ca.crt` and copy the CA to the web host ([recipe](../recipes/verify-full-tls.md)) | `doctor`: "verify-full: server certificate chains to the CA"; the app connects with `DB_SSLMODE=verify-full` | `TLS_MODE=require` and `upgrade`; the app back to `DB_SSLMODE=require` |
| 14 | Monitoring | `-- monitor-user`, then `monitor.sh plan` and `install` on each node, agents first ([monitor](../tools/monitor.md#typical-rollout-two-nodes-hub-on-web), [checklist 07](../checklists/07-monitoring.md)) | `monitor.sh doctor` 0 problems; Prometheus targets up through `monitor.sh tunnel` | `monitor.sh remove <unit>` (files kept) |
| 15 | Add-on keys in the app `.env` | `bin/workbench env init --host $WEB --env <env> --site <domain> --addons --dry-run`, then without `--dry-run` | the output lists the add-ons and changed keys, no values; `env check` clean | the `.env.bak.*` the tool wrote |

`pg-major-upgrade` and `migrate-managed` are not part of this rollout. Run them only when you need them:
[pg-major-upgrade](../recipes/pg-major-upgrade.md), [migrate-to-managed](../recipes/migrate-to-managed.md).

## When something fails

Stop at the failing step. Don't skip ahead: later steps assume earlier ones. Read
[troubleshooting](../troubleshooting.md), fix, re-run that step's verify, then continue. If the DB is
unhealthy and you can't tell why, restore the task 1 snapshot.

## Lessons learned

- Run everything from the workstation. Running `scp` while already logged into the server was the most
  common mistake in the original setup (`remote-run.sh` exists because of it).
- `--expect-ip` is the wrong-server guard. Never set it to `skip` on a live run.
- Snapshot first, even though the upgrade takes a savepoint: the snapshot is the only thing that also covers
  the host (packages, sshd, ufw).
