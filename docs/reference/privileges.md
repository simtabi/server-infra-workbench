# Privilege model

What each database login can do, on every engine the manager runs (Postgres, MySQL, MariaDB). The manager
applies this in `install`, `upgrade`, `create-db`, `create-user`, `grant` and `env-apply`, and `doctor` checks
it. The reasons are in [ADR 0010](../adr/0010-least-privilege-database-roles.md).

## The table

| Privilege | Default app user | Read-only user | Why |
|---|---|---|---|
| Connect to its own database | Yes | Yes | each login is scoped to one database; nothing else is reachable |
| Create, change and drop tables in its own schema (migrations) | Yes | No | Laravel runs `php artisan migrate` with the app login during deploys; a read-only login must never change the schema |
| Read, insert, update and delete rows | Yes | Read only | the app needs full DML; reporting tools, analysts and support people only need to read, and a leaked read-only password can't change data |
| Create new databases (tenants) | Only if turned on for that environment | No | multi-tenant packages create one database per tenant at runtime; elsewhere `CREATEDB` is just extra blast radius, so it is off by default |
| Touch other databases | No | No | a bug or SQL injection in stg must not reach prd, and one client's app must not reach another's |
| Superuser, create roles, replication, bypass row-level security | Never | Never | a superuser can read any file the server can, run programs, drop everything and create new logins: SQL injection would become full server compromise. These stay with the admin login used by the manager |
| Drop the database itself | No (admin only) | No | dropping a database is the one mistake a backup restore takes hours to fix; only the manager does it, after a backup, as a soft drop (`__trash_<ts>`) |

"Turned on" means `--tenants` on `create-db`, `PG_APP_CREATEDB=1` for the single-database layout, or the
environment listed in `TENANT_ENVS` for the environment layout ([naming](naming.md)).

## PostgreSQL

| Login | Attributes | Grants |
|---|---|---|
| admin (`PG_ADMIN_USER`, default `vsw_admin`) | `SUPERUSER`; used by the manager, backups and admin work. `pg_hba` allows it only from the compose subnet and `VPC_CIDR`; its password stays in `/opt/db/.env` | owns every database, so only it can `DROP DATABASE` |
| app (`PG_USER`, or `<app>_<env>_app`) | `LOGIN NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS`, plus `CREATEDB` only when tenants are on | `CONNECT, TEMPORARY` on its database; owns schema `public` (or is a member of `<app>_<env>_owner`, which does) |
| read-only (`<owner>_ro` from `create-db --readonly-user`, or `<app>_<env>_ro`) | `LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS` | `CONNECT`, `USAGE` on `public`, `SELECT` on tables and sequences, plus default privileges for new tables |
| migrator (`<app>_<env>_migrator`, only with `ENV_MIGRATOR=1`) | as app, never `CREATEDB` | member of `_owner`; the app login then gets DML only |
| `pgbouncer_auth` | `LOGIN`, nothing else | `EXECUTE` on `pgbouncer.get_auth(text)` (a `SECURITY DEFINER` lookup that never returns superusers) |

- `REVOKE ALL ON DATABASE ... FROM PUBLIC` on every managed database, so a login can't connect to a database
  it wasn't granted.
- `REVOKE CREATE ON SCHEMA public FROM PUBLIC` (already the default since Postgres 15).
- `pg_hba.conf` limits each environment's roles to that environment's allow list (`ALLOW_<env>`, default the
  VPC range) with `scram-sha-256`.
- Postgres has no way to stop a role from dropping a database it created. Tenant databases are owned by the
  app login that created them, so in protected environments the app should soft-delete tenants and leave the
  purge to the manager (`drop-db` renames to `__trash_<ts>`, `purge-trash` removes it after `TRASH_DAYS`).

## MySQL and MariaDB

| Login | Grants |
|---|---|
| `root` | `localhost`, `127.0.0.1` and the compose subnet only. `root@'%'` is removed by `upgrade` and never created on new installs |
| app (`<user>@'MY_APP_HOST'`) | on `` `db`.* `` only: `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES, CREATE VIEW, SHOW VIEW, TRIGGER, CREATE ROUTINE, ALTER ROUTINE, EXECUTE, CREATE TEMPORARY TABLES, LOCK TABLES, EVENT` |
| app with tenants | the same list again on `` `db\_t\_%`.* `` (the underscores are escaped, so the pattern matches only that prefix) |
| `--readwrite` user | `SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE TEMPORARY TABLES, LOCK TABLES, SHOW VIEW` |
| read-only | `SELECT, SHOW VIEW` |

- No global privileges, `GRANT OPTION`, `FILE`, `SUPER` or `PROCESS` for any app or read-only user.
- `local_infile=0`; MariaDB also sets `secure_file_priv`.
- **Note:** in MySQL and MariaDB, `DROP` on `` `db`.* `` also allows `DROP DATABASE db`. There is no privilege
  that allows dropping tables but not the schema. Protected environments rely on the backup taken before
  every destructive command and the 30-day dump of dropped databases (`DROPPED_DUMP_DAYS`), not on grants.
- MySQL user names are at most 32 characters, so `env-apply` refuses an `APP` that makes `<app>_<env>_app`
  longer.

## MongoDB

Not managed. See [ADR 0009](../adr/0009-mongodb-off-by-default.md).

## Checking it

```sh
sudo ./docker-db-server-manager.sh doctor            # "Isolation" and "MySQL/MariaDB" sections
sudo ./docker-db-server-manager.sh list-users all    # attributes and grants per login
sudo ./docker-db-server-manager.sh env-sql prd       # the exact SQL for a server this tool doesn't manage
```
