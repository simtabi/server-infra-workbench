# 0010. Least-privilege database roles (the 1.4.0 role split)

- Status: Accepted
- Date: 2026-10-31

## Context

Before 1.4.0 the Postgres app login (`PG_USER`) was the container's bootstrap superuser, and MySQL/MariaDB
had `root@'%'`. An SQL injection or a bad migration could drop any database, read other environments, or
change roles. Laravel still needs to run migrations (DDL in its own schema), and multi-tenant apps need to
create tenant databases at runtime.

## Decision

- One admin superuser (`PG_ADMIN_USER`, default `vsw_admin`) for the manager, backups and admin work. It owns
  every central database, so only it can drop one.
- The app login is never superuser and never has `CREATEROLE`, `REPLICATION` or `BYPASSRLS`. It owns schema
  `public` (or belongs to the env's `_owner` role), so migrations work. `CREATEDB` (Postgres) or prefix-escaped
  grants on `` `<db>\_t\_%`.* `` (MySQL/MariaDB) only where tenants are turned on.
- Read-only logins get `CONNECT` + `SELECT` only. Optional `ENV_MIGRATOR=1` splits DDL into a separate login.
- `REVOKE ALL ON DATABASE ... FROM PUBLIC`; `pg_hba` per env; no `root@'%'`; `local_infile=0`.
- PgBouncer looks passwords up through a `SECURITY DEFINER` function that never returns superusers.
- `upgrade` migrates existing servers (`role-split`, reversible with `role-split --rollback`); `doctor` checks it.
- The full table is [privileges](../reference/privileges.md).

## Consequences

- Postgres can't stop a role from dropping a database it created, so tenant databases in protected envs are
  soft-deleted by the app and purged by the manager.
- MySQL `DROP` on `db.*` also allows `DROP DATABASE`; protected envs rely on fresh backups and soft-drop dumps.
- Extensions that need superuser are created by the manager (`create-db --extensions`), not the app.
