# 0015. Named master users, idempotent create-db and live engine toggles (manager 1.6.0)

- Status: Accepted
- Date: 2026-11-01

## Context

[ADR 0010](0010-least-privilege-database-roles.md) split admin and app logins on Postgres, but on MySQL and
MariaDB the only admin was `root`, limited to the server itself, so a DB client on a workstation had no
admin login. `create-db` refused to run twice, which made it awkward in runbooks. Switching an engine off
meant editing the config and re-running `install`, and a Postgres-only app still paid the RAM of MySQL and
MariaDB.

## Decision

- One master login per engine, named in the config: `PG_ADMIN_USER` (unchanged, `vsw_admin`), and
  `MYSQL_ADMIN_USER` / `MARIADB_ADMIN_USER` (default `siwo_admin`) limited to `MY_ADMIN_HOSTS` (default the
  Docker network and `VPC_CIDR`; never `%` or `/0`). `root` stays server-local. Passwords are generated on the
  server into `/opt/db/.env` (600), re-synced on every converge, never printed; `admin-creds --out` is the
  only way to read one.
- Every database gets its own owner login named after it, never a superuser and never a master; an optional
  `<name>_ro`. `create-db` and `create-user` create only what is missing and keep existing passwords.
- `ENABLE_*` toggles are applied with `engines apply`, which touches only the changed services and proves the
  others were not restarted. Volumes are kept unless `--purge` with a typed confirmation.
- Every key can be written `SIWO_DB_<KEY>`, so the workstation `.env` uses one prefix. The `.env` is
  git-ignored and guarded by `make env-check` and a pre-commit hook.

## Consequences

- Renaming the Postgres superuser on an existing server is not supported; `vsw_admin` stays.
- The workstation `.env` holds a copy of the master passwords; the server's `/opt/db/.env` stays the source
  of truth, so the copy is synced from `admin-creds`, not pushed.
- A master with `GRANT OPTION` from the VPC is a powerful login: it is reachable only over the private network
  (and an SSH tunnel), and `MY_ADMIN_GRANT_OPTION=0` or `MYSQL_ADMIN_USER=none` turns that off.
