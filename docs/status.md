# Status: done vs open

## Done

| Area | What |
|---|---|
| DB server | Postgres + PostGIS + pgvector, PgBouncer (session, scram), MySQL, MariaDB, each optional; bound to the private IP only; idempotent `install`; `init`, `verify`, `doctor`, `create-db`, user management (`create-user grant rotate-password drop-* list-*`), optional loopback-only Adminer |
| Backups | nightly cron, atomic (`.partial` then rename), free-space check, users/grants for MySQL/MariaDB, `KEEP` pruning, offsite `BACKUP_HOOK`, logrotate |
| Upgrades | config file first, wrong-server guard, `remote-run.sh` from the workstation |
| Web | `update-env-db.sh` (idempotent, masked, `.bak` pruning), `check-db-reach.sh` |
| Deploy | generic Ploi script: `laravel`/`generic` presets, optional hooks, zero-downtime or in-place, first-install marker, `.env` symlink for Ploi's editor, `chmod 600` |
| Docker web | Caddy + php-fpm compose with automatic HTTPS |
| Guided upgrade | manager 1.3.0 `upgrade`: preflight, diff, snapshot offer, verified backup, savepoint, apply, verify, auto-rollback, lock, redacted log |
| Platform APIs | PHP 8.4 clients for DigitalOcean (droplets, snapshots, actions), Cloudflare (zones, DNS upsert/delete), Ploi (servers, sites, deploy), GCP (instances, snapshots, firewalls); pending actions, dry runs, audit log |
| CLI | `bin/workbench`: shell tools, `do`/`cf`/`ploi`/`gcp`, `credentials`, `py` |
| Quality | shellcheck, smoke tests, deploy sandbox, Docker upgrade integration test, link check, compose validation, project-neutral core check, Pint, PHPStan max, PHPUnit, Python unittest, CI |

## Open / Roadmap (ranked)

Ranked by risk to data first, then by how likely the gap is to bite.

| # | Gap | Why it matters | Suggested approach |
|---|---|---|---|
| 1 | <a id="restore-test"></a>**Restore test** | A backup that has never been restored is unproven. Dumps can be empty, truncated or fail to load into a newer server, and you only find out on the day you need them. | Until it's automated, restore by hand every month on a scratch droplet: `restore <dir> all`, then `verify` and check that the app data is there. Later, add a `restore-test` command that loads the newest backup into throwaway containers on another port, counts tables and rows, and removes them. Run it weekly from cron. |
| 2 | <a id="point-in-time-recovery"></a>**Point-in-time recovery (up to 24 h data loss)** | Backups are nightly logical dumps, so a disk loss or bad migration at 23:00 loses almost a day of writes. | Shorter term, run backups more often (`CRON_TIME`, e.g. every 6 h) and copy them offsite with `BACKUP_HOOK`. Proper fix: Postgres WAL archiving with pgBackRest or wal-g to object storage (Spaces/S3), which gives restore to any second. For MySQL/MariaDB, keep the binlogs. A managed database is the alternative. |
| 3 | <a id="monitoring"></a>**Monitoring and alerts** | Nothing pages you on a failed backup, a full disk, a stopped container or a down site. Every failure is found by hand. | Ploi server monitoring and DigitalOcean alerts (CPU, disk, memory). Add an uptime check on `https://<site>/up` and a daily cron that runs `doctor` and mails on a non-zero exit. Ideas: [security.md](security.md#monitoring-not-built-in). |
| 4 | <a id="postgres-major-upgrade"></a>**Major Postgres upgrade** | A new major version can't start on the old data directory, so bumping `PG_BASE_IMAGE` (e.g. 18 to 19) without a procedure breaks the database. | Today: `backup`, `uninstall`, remove the `db_postgres` volume, set the new image, `install`, `restore <dir> postgres`, `verify`. Planned: an `upgrade` command that does this with a guard, or uses `pg_upgrade` in a helper container. Minor versions only need `install` (pull and recreate). |
| 5 | <a id="create-db-pgbouncer"></a>**~~`create-db` users vs PgBouncer~~ (done in 1.2.0)** | Fixed: PgBouncer uses `auth_user=PG_USER` + `auth_query`, so every Postgres login role pools through 6432. | Apply on an existing server with `install` ([rollout plan](recipes/roll-out-a-manager-upgrade.md)). |
| 6 | <a id="private-network-encryption"></a>**Encryption on the private network** | Web-to-DB traffic crosses the DigitalOcean VPC unencrypted. That's isolated per account, but it isn't encrypted. | Postgres: `ssl=on` with a certificate, then `DB_SSLMODE=require` (or `verify-full` with your own CA). MySQL/MariaDB: `require_secure_transport`. PgBouncer: `client_tls_*`. Or run WireGuard between the droplets. |
| 7 | <a id="platform-coverage"></a>**Platform API coverage** | The clients cover what the runbooks need today (snapshots, DNS, deploys, inventory). Creating droplets, firewalls or Ploi sites still happens in the dashboards. | Add endpoints as the runbooks need them, each with a mocked test, a CLI command and a docs row ([platform-api.md](tools/platform-api.md#adding-a-platform)). Wire `remote-run.sh` to `bin/workbench do snapshot` as an alternative to doctl. |
