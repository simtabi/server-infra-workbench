# Connecting local DB clients

How to reach the databases on the DB server from your workstation with TablePlus, DBeaver, DataGrip/PhpStorm,
`psql` or `mysql`. The database ports listen only on the server's private VPC IP, so every connection goes
through SSH (port 22, key auth). Nothing database-related is ever opened on the public IP.

Placeholders used below: `<db-ssh-alias>` is the server's alias in `~/.ssh/config` (or `user@<public-ip>`),
`<db-private-ip>` its private VPC IP (`ip -4 -o addr show eth1` on the server). Logins and databases come
from [Users and privileges](users-and-privileges.md).

## Ports

| Engine | Server port (on the private IP) | Local tunnel port | `.env` key for the local port |
|---|---|---|---|
| PostgreSQL (direct) | 5432 | 15432 | `SIWO_DB_LOCAL_PG` |
| PgBouncer (session mode) | 6432 | 16432 | `SIWO_DB_LOCAL_PGBOUNCER` |
| MySQL | 3306 | 13306 | `SIWO_DB_LOCAL_MYSQL` |
| MariaDB | 3307 | 13307 | `SIWO_DB_LOCAL_MARIADB` |
| Adminer (optional) | 8081 on `127.0.0.1` | 8081 | `SIWO_DB_LOCAL_ADMINER` |

Local ports are offset so they don't clash with databases running on your machine. An engine switched off
with `ENABLE_*=0` has no port; check with `sudo /root/docker-db-server-manager.sh engines` on the server.

## Which login to use

| You want to | Login | Port |
|---|---|---|
| administer (create users, look at everything) | the engine's master: `vsw_admin` (Postgres), `siwo_admin` (MySQL/MariaDB) | Postgres **5432** only (PgBouncer refuses superusers) |
| work in one app database | that database's owner (`create-db <name>` made login `<name>`) | 5432 or 6432 (what the app uses) |
| read data safely | `<name>_ro`, or `create-user <user> <db> --readonly` | 5432 or 6432 |

Get a password into a 600 file on the server, copy it into your client (or your `.env`), then delete the file:

```bash
src/shell/db/remote-run.sh --host <db-ssh-alias> --expect-ip <db-private-ip> --no-upload -- admin-creds postgres --out /root/pg-admin.creds
ssh -t <db-ssh-alias> 'sudo cat /root/pg-admin.creds && sudo shred -u /root/pg-admin.creds'
```

Use `admin-creds mysql` / `admin-creds mariadb` for the other masters; app logins come from
`create-db ... --out FILE` or `rotate-password <user> [engine] --out FILE`. Store them in your password
manager or the client's keychain, never in a tracked file.

## 1. Open the tunnel

With `SIWO_DB_SSH_HOST` and `SIWO_DB_PRIVATE_IP` set in your `.env` (copied from `.env-example`):

```bash
bin/siwo tunnels db-tunnel postgres pgbouncer          # Ctrl-C closes it
bin/siwo tunnels db-tunnel all --background            # every engine; stop: pkill -f 'ssh -N .*<db-ssh-alias>'
bin/siwo tunnels db-tunnel --print all                 # show the ssh command only
```

Or pass them: `src/shell/tunnels/db-tunnel.sh --host <db-ssh-alias> --private-ip <db-private-ip> mysql`. The
local ends bind to `127.0.0.1`, so nothing else on your network can use the tunnel.

By hand with `ssh -L` (one `-L` per engine):

```bash
ssh -N -L 127.0.0.1:15432:<db-private-ip>:5432 <db-ssh-alias>      # Postgres direct
ssh -N -L 127.0.0.1:16432:<db-private-ip>:6432 <db-ssh-alias>      # PgBouncer
ssh -N -L 127.0.0.1:13306:<db-private-ip>:3306 <db-ssh-alias>      # MySQL
ssh -N -L 127.0.0.1:13307:<db-private-ip>:3307 <db-ssh-alias>      # MariaDB
ssh -N -L 127.0.0.1:8081:127.0.0.1:8081 <db-ssh-alias>             # Adminer (it listens on the server's loopback)
```

Then point any client at `127.0.0.1` and the local port.

## 2. Command line

```bash
psql "host=127.0.0.1 port=15432 user=vsw_admin dbname=postgres"   # master, direct port
psql "host=127.0.0.1 port=16432 user=<app-user> dbname=<app-db>"  # app login through PgBouncer
mysql   -h 127.0.0.1 -P 13306 --protocol=TCP -u siwo_admin -p
mariadb -h 127.0.0.1 -P 13307 --protocol=TCP -u siwo_admin -p
```

`-p` and `psql` prompt for the password; don't put it on the command line (it lands in your shell history and
`ps`). `--protocol=TCP` stops the MySQL client from trying a local socket for `127.0.0.1`. With `TLS_MODE`
on, Postgres requires TLS: add `sslmode=require`, or `sslmode=verify-ca sslrootcert=<ca.crt>` (the CA from
`tls-ca --out`). `verify-full` also checks the host name, which is the private IP, so it fails on `127.0.0.1`
through a tunnel; see [verify-full TLS](../recipes/verify-full-tls.md).

## 3. TablePlus

Either open the tunnel first and connect to `127.0.0.1:<local port>` without SSH, or let TablePlus open it:
new connection, pick the engine, then **Over SSH**:

| Field | PostgreSQL | MySQL | MariaDB |
|---|---|---|---|
| Host / Port | `<db-private-ip>` / `5432` (or `6432`) | `<db-private-ip>` / `3306` | `<db-private-ip>` / `3307` |
| User | master or app login | master or app login | master or app login |
| Database | the database (or `postgres`) | optional | optional |
| SSL mode | `PREFERRED` / `REQUIRE` | `PREFERRED` | `PREFERRED` |
| Over SSH: server / port / user | the server's public address, `22`, your SSH user | same | same |
| Over SSH: key | *Use SSH key*, pick your key file | same | same |

TablePlus can import an `~/.ssh/config` alias but does not follow `ProxyJump`; use the pre-opened tunnel for
jump hosts.

## 4. DBeaver

New connection, pick the driver:

- **Main** tab: Host `<db-private-ip>`, port `5432` / `6432` / `3306` / `3307`, database, user, password
  (*Save password* stores it in DBeaver's secure storage).
- **SSH** tab: *Use SSH Tunnel*, host the server's public address, port 22, your SSH user, *Authentication:
  Public Key* with your key file. *Test tunnel configuration*, then *Test connection*.
- MySQL 8+/MariaDB: under *Driver properties* set `allowPublicKeyRetrieval=true` only if the driver asks;
  `useSSL=false` is fine because the traffic is inside SSH.

Or with a pre-opened tunnel: Host `127.0.0.1`, the local port, SSH off.

## 5. DataGrip and PhpStorm

*Database* tool window, *+* then *Data Source* and the engine:

- **General**: Host `<db-private-ip>`, port as above, user, password (*Save: Forever* uses the OS keychain),
  database.
- **SSH/SSL** tab: *Use SSH tunnel*, then *...* to add an SSH configuration: host the server's public address,
  port 22, your SSH user, *Authentication type: Key pair* (or *OpenSSH config and authentication agent*, which
  reads `~/.ssh/config` and your agent).
- *Test Connection*, and download the driver when asked.

Or with a pre-opened tunnel: Host `127.0.0.1`, the local port, no SSH configuration.

## 6. Adminer (browser)

Off by default. Turn it on with `engines apply --set ENABLE_ADMINER=1`, open the tunnel
(`bin/siwo tunnels db-tunnel adminer`), browse to `http://127.0.0.1:8081` and log in with the Compose
service name as the server: `postgres`, `pgbouncer`, `mysql`, or `mariadb:3306`. Turn it off again with
`ENABLE_ADMINER=0` when done. Details: [Connections](../recipes/connect-to-databases.md#2-admin-web-ui-adminer-optional).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Connection refused` on the local port | the tunnel is not open, or that engine is off (`engines` on the server) |
| `channel ... open failed: connect failed` in the ssh output | wrong `<db-private-ip>` or the engine is off |
| Postgres: `password authentication failed` on 6432 for `vsw_admin` | the master is a superuser; PgBouncer refuses it. Use 5432 |
| MySQL: `Access denied for user 'siwo_admin'@'...'` | the password changed (sync it from `admin-creds`), or the source address is outside `MY_ADMIN_HOSTS` |
| `Can't connect to local MySQL server through socket` | add `--protocol=TCP` |
| The client hangs on SSH | the key is not loaded (`ssh-add -l`) or the client can't read `~/.ssh/config` options such as `ProxyJump` |
