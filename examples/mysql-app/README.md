# Example: a Laravel app on MySQL

Made up: app `shop`, web droplet `web-01` (`10.0.0.6`) on Ploi, DB droplet `db-01` (`10.0.0.5`), VPC
`10.0.0.0/20`, environments `dev` and `stg`. Profile [`mysql-app`](../../config/profiles/mysql-app.conf).

**Why:** an app that already speaks MySQL gains nothing from a Postgres container it never uses. Turning
Postgres and PgBouncer off frees their RAM on a small droplet; the same backups, off-site copies, per-env
databases and least-privilege users apply to MySQL.

```bash
examples/run.sh mysql-app        # validate (offline): RAM, engines, off-site settings
bin/siwo configure --profile mysql-app --client <you> --set APP=shop \
  --set ALERT_EMAIL=<you@example.com> --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
```

Then follow the printed `next:` steps and the [DB checklist](../../docs/checklists/02-db-setup.md).

Checklist:

- [ ] `DB_CONNECTION=mysql` and port 3306 in the app `.env` (written by `bin/siwo env init`, never typed)
- [ ] Off-site bucket created with a key limited to it ([backups](../../docs/backups-and-recovery.md))
- [ ] Restore drill done once ([monthly restore drill](../../docs/checklists/monthly-restore-drill.md))

Lesson: point-in-time recovery for MySQL is binlog shipping, and binlog replay is not container-tested yet
([status](../../docs/status.md#point-in-time-recovery)). Treat the nightly dump as the tested restore path.
