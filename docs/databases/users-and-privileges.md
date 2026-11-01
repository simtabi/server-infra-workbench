# Database users and privileges

How the DB manager (`src/shell/db/docker-db-server-manager.sh`, 1.6.0+) creates databases and logins, links
them, and which settings control it. The per-privilege table is in [Privileges](../reference/privileges.md);
the reasons are in [ADR 0010](../adr/0010-least-privilege-database-roles.md). Connecting a DB client from your
workstation is in [Connecting local DB clients](connecting-local-clients.md).

## The three kinds of login

| Login | One per | Name | Used by | Can |
|---|---|---|---|---|
| **Master (admin)** | engine | `PG_ADMIN_USER` (default `vsw_admin`), `MYSQL_ADMIN_USER` / `MARIADB_ADMIN_USER` (default `siwo_admin`) | you, your DB client, the manager | everything (`SUPERUSER` on Postgres; `MY_ADMIN_PRIVS` on `*.*` on MySQL/MariaDB) |
| **Owner (app)** | database | the database name (`create-db shop` makes login `shop`), or `--owner U` | the application (`DB_USERNAME`) | DDL and DML in its own database only; never a superuser |
| **Read-only** (optional) | database | `<owner>_ro` | reporting, support, analysts | `SELECT` in that database only |

Extra logins for an existing database come from `create-user <user> <db> [--readonly|--readwrite]`, and an
existing login gets another database with `grant`. `root` on MySQL/MariaDB still exists but only for
`localhost`, `127.0.0.1` and the Docker network: the manager uses it inside the container, you use the master.

## How a database and its owner are created

```mermaid
flowchart TD
  A["create-db shop [engine] [--owner U] [--readonly-user] [--tenants]"] --> B{database exists?}
  B -- no --> C[create database shop]
  B -- yes --> D[keep it]
  C --> E{owner login exists?}
  D --> E
  E -- no --> F["create login shop, random password (openssl), never superuser"]
  E -- yes --> G["refuse if superuser / master; otherwise keep its password"]
  F --> H[apply the grants: database CONNECT, schema public owned by the owner, PUBLIC revoked]
  G --> H
  H --> I{read-only? --readonly-user or DB_READONLY_USER=1}
  I -- yes --> J["shop_ro: SELECT on current and future tables"]
  I -- no --> K[done]
  J --> K
  K --> L["credentials: printed once, or a new 600 file with --out (only for logins created now)"]
```

On Postgres the database itself is owned by `PG_ADMIN_USER`, so the app cannot drop it; the owner login owns
schema `public` and gets `CONNECT, TEMPORARY`. On MySQL/MariaDB the owner gets `MY_OWNER_PRIVS` on
`` `shop`.* `` only. PgBouncer finds new Postgres logins at once (`auth_query`); it refuses superusers, so the
Postgres master always connects on the direct port (5432), never 6432.

### Re-running is safe (idempotent)

`create-db` and `create-user` only create what is missing:

- an existing database is kept (its data is never touched); an existing login keeps its password and only its
  grants are re-applied. The output says `already existed: grants re-applied, password unchanged`;
- no credentials file is written for a login that already existed (a new password needs
  `rotate-password <user> [engine] --out FILE`);
- an existing Postgres database whose schema `public` belongs to another login is refused, as is an owner that
  is a superuser or one of the master logins.

So a deploy script or runbook can call `create-db shop` every time.

## Master users

- **Postgres:** `PG_ADMIN_USER` is the bootstrap superuser created by `install`. Keep `vsw_admin` on servers
  installed before 1.6.0; renaming the superuser later is not supported. `pg_hba` allows it only from the
  Docker network and `VPC_CIDR`, over TLS when `TLS_MODE` is on.
- **MySQL/MariaDB:** `MYSQL_ADMIN_USER` / `MARIADB_ADMIN_USER` (default `siwo_admin`; `none` = no master, use
  root on the server). The manager creates it on every converge (`install`, `upgrade`, `engines apply`) as
  `user@<cidr>` for each entry of `MY_ADMIN_HOSTS` (default: the Docker network and `VPC_CIDR`; `0.0.0.0/0`
  and `%` are refused), drops hosts no longer listed, re-syncs its password from `/opt/db/.env` and grants
  `MY_ADMIN_PRIVS` (default `ALL PRIVILEGES`) on `*.*`, with `GRANT OPTION` when `MY_ADMIN_GRANT_OPTION=1`.
  `root` is refused as a master name.
- **Passwords:** generated on the server (`openssl rand -hex 24`) the first time a key is written to
  `/opt/db/.env` (600) and never overwritten afterwards. A value passed to the manager as
  `PG_ADMIN_PASSWORD`, `MYSQL_ADMIN_PASSWORD` or `MARIADB_ADMIN_PASSWORD` (or the `SIWO_DB_` form) seeds a key
  that does not exist yet; it must match `[A-Za-z0-9._-]{16,128}`. The manager never prints them.
- **Reading one:** `admin-creds <postgres|mysql|mariadb> --out FILE` writes `DB_HOST`, `DB_PORT`,
  `DB_USERNAME`, `DB_PASSWORD` to a new 600 file (it refuses to overwrite one and never prints the password).
  Copy the values into your DB client or your workstation `.env`, then delete the file.

```bash
sudo /root/docker-db-server-manager.sh admin-creds mysql --out /root/mysql-admin.creds
sudo /root/docker-db-server-manager.sh create-db shop postgres --readonly-user --out /root/shop.creds
sudo /root/docker-db-server-manager.sh create-db shop postgres          # again: nothing new, grants re-applied
sudo /root/docker-db-server-manager.sh create-user shop_report shop --readonly
sudo /root/docker-db-server-manager.sh list-users all
```

## Settings

All keys live in `/etc/docker-db-server-manager.conf` (see `config/db-server.env.example` and
[Configuration keys](../reference/configuration-keys.md)); the environment overrides the file. Every key can
also be written `SIWO_DB_<KEY>`, the form the workstation `.env` uses; a plain `<KEY>` wins over it.

| Key | Default | What |
|---|---|---|
| `PG_ADMIN_USER` | `vsw_admin` | Postgres master (superuser) |
| `MYSQL_ADMIN_USER`, `MARIADB_ADMIN_USER` | `siwo_admin` | MySQL/MariaDB master; `none` disables |
| `MY_ADMIN_HOSTS` | Docker network + `VPC_CIDR` | CIDRs or IPs the MySQL/MariaDB master may log in from |
| `MY_ADMIN_PRIVS` | `ALL PRIVILEGES` | the master's privileges on `*.*` |
| `MY_ADMIN_GRANT_OPTION` | `1` | the master may grant (needed to manage other users from a client) |
| `PG_APP_CREATEDB` | `1` | the single-layout Postgres app login may create tenant databases |
| `DB_READONLY_USER` | `0` | `1` = every `create-db` also makes `<name>_ro` |
| `MY_APP_HOST` | `%` | host part of MySQL/MariaDB app users (ports listen on the private IP only) |
| `MY_OWNER_PRIVS`, `MY_RW_PRIVS`, `MY_RO_PRIVS` | see [Privileges](../reference/privileges.md#mysql-and-mariadb) | database-level privilege sets; `ALL`, `GRANT`, `FILE`, `SUPER`, `PROCESS`, `SHUTDOWN`, `RELOAD`, `REPLICATION`, `CREATE USER` are refused |

Passwords are never config keys: they live only in `/opt/db/.env` on the server.

### The workstation `.env`

`.env-example` (tracked) lists the `SIWO_DB_*` keys with empty passwords and `<placeholders>`; copy it to
`.env` (git-ignored, `chmod 600`). `make env-check` (part of `make ci`) and the `no-env-files` pre-commit hook
fail if a `.env` file is ever tracked or staged.

- `SIWO_DB_ENABLE_*`: the engine toggles, applied with `bin/siwo db engines` (below).
- `SIWO_DB_*_ADMIN_USER` / `_PASSWORD`: your record of the master logins. The server keeps the live passwords;
  sync your copy from `admin-creds`. No tool sends the passwords in this file to a server.
- `SIWO_DB_SSH_HOST`, `SIWO_DB_PRIVATE_IP`, `SIWO_DB_LOCAL_*`: used by `bin/siwo tunnels db-tunnel` and
  `bin/siwo db engines`.

## Turning engines on and off

`ENABLE_POSTGRES`, `ENABLE_PGBOUNCER`, `ENABLE_MYSQL`, `ENABLE_MARIADB`, `ENABLE_ADMINER` (`1`/`0`). A
disabled engine has no container, port, firewall rule, backup or check. `engines apply` changes only the
services whose setting changed; the others keep their containers and are not restarted, so turning MySQL and
MariaDB off on a Postgres server causes no Postgres downtime.

```bash
sudo /root/docker-db-server-manager.sh engines                                   # status (read-only)
sudo /root/docker-db-server-manager.sh engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0 --dry-run
sudo /root/docker-db-server-manager.sh engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0   # type APPLY
```

`apply` prints the plan, asks you to type `APPLY` (`--yes` skips it), takes a backup when a data engine is
stopped, stops and removes only those containers, writes the setting to the config file, starts and converges
the engines turned on, prunes their firewall rules, checks that the untouched containers are the same ones
and runs `doctor`. Data volumes are kept: turning an engine back on brings its data and users back.
`--purge` deletes the volumes of every engine that is off, after a typed `DELETE-<volume>` (or
`WORKBENCH_CONFIRM='DELETE <volume>'`). `engine enable|disable <engine>` is the one-engine form.

From the workstation, `bin/siwo db engines` reads the toggles from `.env` and runs the same thing through
`remote-run.sh` (it uploads this checkout's manager unless `--no-upload`):

```bash
bin/siwo db engines status
bin/siwo db engines plan                 # engines apply --dry-run on the server
bin/siwo db engines apply                # the server asks you to type APPLY
bin/siwo db engines plan --print         # show the remote-run command only
```

Only `SIWO_DB_ENABLE_*`, `SIWO_DB_SSH_HOST` and `SIWO_DB_PRIVATE_IP` are read (the file is never sourced); a
toggle missing from the file is not sent. PgBouncer needs Postgres, so `ENABLE_POSTGRES=0` with
`ENABLE_PGBOUNCER=1` is refused.
