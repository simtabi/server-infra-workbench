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
| Secrets file on the server | `$ENV_SECRETS_DIR/<env>.env` (chmod 600) | `/etc/vps-server-workbench/secrets/prd.env` |

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
