# Configuration keys (DB server manager)

Every key `docker-db-server-manager.sh` reads from `/etc/docker-db-server-manager.conf` (or `--config FILE`,
`DBM_CONFIG=FILE`). Environment variables override the file. The file holds no secrets: passwords are
generated into `$DB_DIR/.env` and `$ENV_SECRETS_DIR/<env>.env` (both chmod 600). This page is generated from
[config/db-server.env.example](../../config/db-server.env.example); edit the example, then run
`python3 tests/docs/gen-config-keys.py`.

## engines (1 = on, 0 = off)

| Key | Default | Notes |
|---|---|---|
| `ENABLE_POSTGRES` | `1` | A disabled engine gets no container, port, firewall rule, backup or check. PgBouncer needs Postgres. |
| `ENABLE_PGBOUNCER` | `1` |  |
| `ENABLE_MYSQL` | `1` |  |
| `ENABLE_MARIADB` | `1` |  |
| `ENABLE_ADMINER` | `0` | Optional Adminer web UI (MySQL, MariaDB, PostgreSQL). Off by default. When on it binds to 127.0.0.1 only (not the VPC, no ufw rule); reach it with an SSH tunnel. See docs/recipes/connect-to-databases.md. |

## network

| Key | Default | Notes |
|---|---|---|
| `PRIVATE_IP` | (empty) | Private VPC IP every port binds to. Default: the IPv4 on PRIVATE_IFACE. Find it with: ip -4 -o addr show eth1 |
| `PRIVATE_IFACE` | `eth1` |  |
| `EXPECTED_PRIVATE_IP` | (empty) | Refuse to run unless this IP is on the host (wrong-server guard). Recommended. |
| `VPC_CIDR` | `10.0.0.0/8` | ufw source range allowed to reach the DB ports (your DO VPC range). |

## paths

| Key | Default | Notes |
|---|---|---|
| `DB_DIR` | `/opt/db` |  |
| `BACKUP_DIR` | (unset; example `/opt/db/backups`) | BACKUP_DIR defaults to $DB_DIR/backups |
| `KEEP` | `7` |  |
| `CRON_TIME` | `15 3 * * *` |  |
| `CRON_FILE` | `/etc/cron.d/docker-db-server-backup` |  |
| `CRON_LOG` | `/var/log/docker-db-server-backup.log` |  |
| `MIN_FREE_MB` | `1024` | backup refuses to start with less free space than this (MB) |
| `BACKUP_HOOK` | (unset; example `rclone copy "$1" spaces:my-bucket/db/$(basename "$1")`) | Optional offsite copy, run after every good backup with the backup dir as $1: |
| `WEB_ENV` | (unset; example `/home/ploi/example.com-shared/.env`) | Shown in `env` output as the place to paste the DB_* lines (default: /home/ploi/<site>-shared/.env). |

## PostgreSQL

| Key | Default | Notes |
|---|---|---|
| `PG_USER` | `app` |  |
| `PG_DB` | `app` |  |
| `PG_IMAGE` | `vsw/postgres:18-postgis-pgvector` | 1.4.0 default (neutral tag). Servers on the old local/... tag: change it here; upgrade retags and retires the old one. |
| `PG_BASE_IMAGE` | `postgis/postgis:18-3.6` |  |
| `PGVECTOR_PKG` | `postgresql-18-pgvector` |  |
| `PG_MAX_CONNECTIONS` | `200` |  |
| `PG_EXTENSIONS` | `vector postgis pg_trgm pgcrypto uuid-ossp citext pg_stat_statements` | Created in PG_DB and template1 (so every later database has them). Must exist in the image. |
| `PG_PORT` | `5432` |  |

## PgBouncer (session mode, scram-sha-256)

| Key | Default | Notes |
|---|---|---|
| `PGBOUNCER_IMAGE` | `edoburu/pgbouncer:v1.26.1-p0` |  |
| `PGBOUNCER_PORT` | `6432` |  |
| `PGBOUNCER_MAX_CLIENT_CONN` | `500` |  |
| `PGBOUNCER_POOL_SIZE` | `20` |  |

## MySQL / MariaDB

| Key | Default | Notes |
|---|---|---|
| `MYSQL_IMAGE` | `mysql:9.7` |  |
| `MYSQL_PORT` | `3306` |  |
| `MARIADB_IMAGE` | `mariadb:13` |  |
| `MARIADB_PORT` | `3307` |  |

## Adminer (optional admin UI, loopback only)

| Key | Default | Notes |
|---|---|---|
| `ADMINER_IMAGE` | `adminer:6.1.2-standalone` | Official image, pinned. Check https://hub.docker.com/_/adminer/tags before bumping. |
| `ADMINER_PORT` | `8081` |  |

## hardening (1.4.0)

| Key | Default | Notes |
|---|---|---|
| `PG_ADMIN_USER` | `vsw_admin` | Role split: PG_ADMIN_USER is the only superuser (bootstrap, admin work, backups); PG_USER is the app login: no superuser, no CREATEROLE/REPLICATION/BYPASSRLS, CREATEDB only when PG_APP_CREATEDB=1 (tenant databases). PgBouncer looks users up through PGBOUNCER_AUTH_USER and a SECURITY DEFINER function (never superusers). |
| `PG_APP_CREATEDB` | `1` |  |
| `PGBOUNCER_AUTH_USER` | `pgbouncer_auth` |  |
| `PGBOUNCER_ADMIN_USER` | `pgbouncer_admin` |  |
| `PGBOUNCER_POOL_MODE` | `session` |  |
| `DOCKER_NETWORK` | `vsw_db` | compose network with a fixed subnet |
| `DOCKER_SUBNET` | `172.30.88.0/24` | pg_hba + MySQL root host use it |
| `TLS_MODE` | `off` | off \| require \| verify-full (self-signed CA made on the server; verify-full = clients check CA + host) |
| `TLS_DAYS` | `825` |  |
| `TLS_CA_WEB_PATH` | `/etc/ssl/certs/vsw-db-ca.crt` | where `tls-ca` tells web servers to put the public CA |
| `EXTRA_BIND_IPS` | (empty) | e.g. 10.200.0.1 (wg0); comma or space separated |
| `ALLOW_PUBLIC_BIND` | `0` | 1 = a public EXTRA_BIND_IPS entry is on purpose (TLS_MODE=require is then mandatory) |
| `PEER_REGIONS` | (empty) | app servers' regions, e.g. nyc1; doctor warns on a mismatch |
| `VPC_PEERING` | `0` | 1 = the VPCs are joined by DO VPC peering (cross-region private IPs then work) |
| `METADATA_URL` | `http://169.254.169.254/metadata/v1` | DO metadata (doctor region check) |
| `PG_LOG_MIN_DURATION` | `500ms` |  |
| `PG_LOG_CONNECTIONS` | `on` |  |
| `PG_IMAGE_LEGACY` | `local/postgres:18-postgis-pgvector` | old default tag, retired by upgrade |
| `MARIADB_ED25519` | `0` | 1 = new MariaDB users use ed25519 (PHP mysqlnd cannot) |
| `MY_APP_HOST` | `%` | host part of MySQL/MariaDB app users (ports are VPC-only) |
| `BINLOG_DAYS` | `7` | MySQL/MariaDB binlog retention on the server |
| `STATE_DIR` | `/var/lib/vps-server-workbench/db` | status stamps for doctor/monitoring |
| `DOCKER_GROUP_ALLOW` | (empty) | users allowed in the docker group; doctor warns about any other non-root member |

## monitoring

| Key | Default | Notes |
|---|---|---|
| `MONITOR_USER` | `vsw_monitor` | read-only pg_monitor role for postgres_exporter (CONNECTION LIMIT 5, db postgres only) |
| `MONITOR_PASSWORD_FILE` | `/etc/vsw-monitor/pg-monitor.pass` | 600, written by `monitor-user`; never printed |
| `METRICS_TEXTFILE_DIR` | `/var/lib/vsw-monitor/textfile` | vsw_db.prom for node_exporter; skipped when the folder is missing |

## environments

| Key | Default | Notes |
|---|---|---|
| `APP` | (empty) | empty = no environment layout |
| `ENVS` | `tst dev trn stg prd` |  |
| `TENANT_ENVS` | `tst dev trn stg prd` | default: same as ENVS; envs whose app role may CREATE tenant DBs |
| `PROTECTED_ENVS` | `stg prd` |  |
| `PRD_LOCATION` | `local` | local \| droplet \| managed (prd not on this host) |
| `ENV_MIGRATOR` | `0` | 1 = separate <app>_<env>_migrator for DDL |
| `ENV_SECRETS_DIR` | `/etc/vps-server-workbench/secrets` |  |
| `FRESH_BACKUP_MIN` | `15` | protected envs: destructive ops need a backup this fresh |
| `TRASH_DAYS` | `7` | soft-dropped Postgres DBs are purged after this |
| `DROPPED_DUMP_DAYS` | `30` | MySQL/MariaDB: dumps of dropped DBs kept this long |

## backups: GFS retention, PITR, off-site, restore tests, alerts

| Key | Default | Notes |
|---|---|---|
| `RETENTION` | (empty) | "daily=14 weekly=8 monthly=12 yearly=2"; empty = KEEP newest |
| `PITR` | `off` | off \| pgbackrest |
| `PITR_DAYS` | `14` |  |
| `PITR_REPO_TYPE` | `s3` | s3 \| posix (posix: a local/volume path, tests and NFS) |
| `PITR_REPO_PATH` | `/pgbackrest` |  |
| `PITR_S3_URI_STYLE` | `host` | host (DigitalOcean Spaces, AWS S3) \| path (Garage, MinIO, SeaweedFS) |
| `PITR_S3_CA_FILE` | (empty) | PEM CA of a private S3 endpoint (self-hosted Garage behind TLS); TLS is always verified |
| `PITR_FULL_CRON` | `30 2 * * 0` |  |
| `PITR_DIFF_CRON` | `30 2 * * 1-6` |  |
| `PGBACKREST_PKG` | `pgbackrest` |  |
| `PGBACKREST_MIN_VERSION` | `2.60` |  |
| `OFFSITE` | `none` | none \| s3 (DigitalOcean Spaces, AWS S3, any S3 API) |
| `OFFSITE_ENDPOINT` | (empty) | e.g. https://ams3.digitaloceanspaces.com |
| `OFFSITE_REGION` | `us-east-1` |  |
| `OFFSITE_BUCKET` | (empty) |  |
| `OFFSITE_PREFIX` | `db/<hostname>` |  |
| `OFFSITE_ENCRYPTION` | `openssl` | openssl (AES-256, key file) \| age (recipients file) |
| `OFFSITE_KEY_FILE` | `/etc/vps-server-workbench/backup.key` | chmod 600 |
| `OFFSITE_CREDS_FILE` | `/etc/vps-server-workbench/offsite.env` | chmod 600: OFFSITE_ACCESS_KEY / OFFSITE_SECRET_KEY |
| `OFFSITE_TOOL` | `rclone` | rclone \| aws |
| `OFFSITE_KEEP_DAYS` | `400` |  |
| `BINLOG_SHIP_CRON` | `*/5 * * * *` |  |
| `RESTORE_TEST_CRON` | `0 5 * * 0` |  |
| `RESTORE_TEST_TIMEOUT` | `3600` |  |
| `DOCTOR_CRON` | `7 * * * *` |  |
| `ALERT_EMAIL` | (empty) |  |
| `ALERT_WEBHOOK` | (empty) | https URL, JSON POST {event,status,host,message} |
| `HEALTHCHECK_URL` | (empty) | check-in URL (healthchecks.io style: /fail on failure) |
| `ALERT_COMMAND` | (empty) | local hook: <cmd> <event> <ok\|fail> <message> |
| `BACKUP_MAX_AGE_H` | `26` |  |
| `RESTORE_TEST_MAX_AGE_D` | `8` |  |

## Per-environment keys (not in the example)

| Key | Default | Notes |
|---|---|---|
| `ALLOW_<env>` | `ALLOW_default` | comma-separated IPv4/CIDR allowed to log in as that env's roles (`pg_hba`); written by `env-init --allow env=CIDR` |
| `ALLOW_default` | `VPC_CIDR` | fallback for envs without their own `ALLOW_<env>` |
| `WORKBENCH_CONFIRM` | (environment only) | the protected env's name (e.g. `prd`) for destructive commands with `--force-prod` and no terminal |
| `DBM_CONFIG` | `/etc/docker-db-server-manager.conf` | (environment only) the config file path |
