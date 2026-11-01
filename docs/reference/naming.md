# Naming contract (environments)

With `APP` set, the DB manager names every database and login the same way on every engine, so scripts,
`.env` files and docs look the same whichever engine you use. The design is in
[Database environments](../database-environments.md).

| Object | Pattern | Example (`APP=myapp`, prd) |
|---|---|---|
| Central database | `<app>_<env>` | `myapp_prd` |
| Tenant databases | `<app>_<env>_t_<id>` | `myapp_prd_t_00042` |
| Soft-dropped database (Postgres) | `<name>__trash_<YYYYmmddHHMMSS>` | `myapp_prd_t_00042__trash_20261031091500` |
| Owner role (no login) | `<app>_<env>_owner` | `myapp_prd_owner` |
| App login | `<app>_<env>_app` | `myapp_prd_app` |
| Read-only login | `<app>_<env>_ro` | `myapp_prd_ro` |
| Migrator login (only with `ENV_MIGRATOR=1`) | `<app>_<env>_migrator` | `myapp_prd_migrator` |
| Secrets file on the server | `$ENV_SECRETS_DIR/<env>.env` (chmod 600) | `/etc/server-infra-workbench/secrets/prd.env` |

## Rules

| Rule | Why |
|---|---|
| `APP` matches `^[a-z][a-z0-9]{1,19}$` | lowercase only, and no `_`, because `_` separates the app, env and tenant parts |
| Environments are `tst dev trn stg prd` | `VALID_ENVS`; anything else is refused by `validate_envs` |
| `TENANT_ENVS` must be a subset of `ENVS` | a tenant prefix for an env with no database makes no sense |
| `<app>_<env>_app` is at most 32 characters | the MySQL/MariaDB user-name limit (`env-apply` refuses longer) |
| Tenant names fit 63 (Postgres) / 64 (MySQL) characters | identifier limits; keep `<id>` short (a zero-padded number) |
| Reserved names are refused | databases `postgres`, `template0`, `template1`, `mysql`, `sys`, `information_schema`, `performance_schema`, `PG_DB`; logins `postgres`, `root`, `mysql`, the `mysql.*`/`mariadb.sys` system users, `healthcheck`, `PG_USER`, `PG_ADMIN_USER` and the PgBouncer logins |

## Environments

| Env | Meaning | Protected by default | Tenants by default |
|---|---|---|---|
| `tst` | automated tests, CI | no | yes |
| `dev` | shared development | no | yes |
| `trn` | training / demo data | no | yes |
| `stg` | staging, production-like | yes | yes |
| `prd` | production | yes | yes |

Protected means destructive commands need `--force-prod`, the env name typed (or `WORKBENCH_CONFIRM=<env>`),
and a verified backup younger than `FRESH_BACKUP_MIN` minutes (taken automatically if missing); drops are soft.

## Frozen identifiers

The project was called `vps-server-workbench` until November 2026 ([ADR 0014](../adr/0014-rename-to-server-infra-workbench.md)).
These names were created on servers under the old name and keep their short `vsw` prefix, because renaming
them would be a migration on every live server (roles, metric history, containers):

| Kind | Names |
|---|---|
| Database roles | `vsw_admin` (Postgres admin), `vsw_monitor` (metrics login), `vsw_migrate` |
| Prometheus metrics, rules, Grafana dashboard uids | `vsw_*` series, `rules/vsw.yml`, `vsw-overview`, `vsw-backups`, `vsw-containers`, `vsw-postgres` |
| Directories and files on servers | `/opt/vsw-monitor`, `/opt/vsw-addons`, `/etc/vsw-monitor.conf`, `/etc/vsw-addons.conf`, `/var/lib/vsw-monitor`, `/etc/ssl/certs/vsw-db-ca.crt`, `/etc/cron.d/vsw-inventory`, `/run/lock/vsw-<tool>.lock` |
| Docker | network `vsw_db`, `vsw-*` add-on compose projects, `vsw-rt-*` restore-test containers, `/etc/postgresql/vsw` in the Postgres container |
| Integration tests | container, network and volume prefix `vsw` (`SIWO_IT_PREFIX`), matching what the code under test creates |

The command is `siwo` and its settings are `SIWO_*`. New resource names use `siw` (temporary files, the
`siw-livetest` tag) or the full `server-infra-workbench` (directories). Labels already written to cloud
resources (`managed-by: workbench`, `managed by workbench`, `workbench: ...` alert descriptions) are kept. Directories under `/etc`, `/var/lib`, `/var/log` and `/usr/local/lib` named
`vps-server-workbench` keep being used on a server where they already exist. `VSW_*` environment
variables still work, with a deprecation notice; use `SIWO_*`.
