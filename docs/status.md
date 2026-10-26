# Status: done vs open

## Done

| Area | What |
|---|---|
| DB server | Postgres + PostGIS + pgvector, PgBouncer (session, scram), MySQL, MariaDB, each optional; bound to the private IP only; idempotent `install`; `init`, `verify`, `doctor`, `create-db` |
| Backups | nightly cron, atomic (`.partial` then rename), free-space check, users/grants for MySQL/MariaDB, `KEEP` pruning, offsite `BACKUP_HOOK`, logrotate |
| Upgrades | config file first, wrong-server guard, `remote-run.sh` from the workstation |
| Web | `update-env-db.sh` (idempotent, masked, `.bak` pruning), `check-db-reach.sh` |
| Deploy | generic Ploi script: `laravel`/`generic` presets, optional hooks, zero-downtime or in-place, first-install marker, `.env` symlink for Ploi's editor, `chmod 600` |
| Docker web | Caddy + php-fpm compose with automatic HTTPS |
| Quality | shellcheck, smoke tests, deploy sandbox, link check, compose validation, project-neutral core check, CI |

## Open (ranked)

1. **Restore test.** Backups are never restored automatically. Do it by hand
   now and then on a scratch droplet (`restore <dir> all`), or add a
   `restore-test` command that loads the newest backup into throwaway containers.
2. **Monitoring/alerts.** Nothing pages on a failed backup, a full disk or a
   down site; see [security.md](security.md#monitoring-not-built-in).
3. **Image upgrades.** No `upgrade` command: bumping `PG_BASE_IMAGE` to a new
   major needs dump, new volume, restore (Postgres majors can't reuse the data dir).
4. **PgBouncer for extra users.** Users from `create-db` connect directly on
   5432; PgBouncer `auth_query` would let them use 6432.
5. **TLS between web and DB.** Traffic stays on the VPC unencrypted; fine on DO's
   private network, add server certificates if your threat model needs it.
6. **Point-in-time recovery.** Nightly logical dumps only (up to 24 h of loss);
   WAL archiving (pgBackRest, wal-g) would close that.
