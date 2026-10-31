# Web server (Ploi)

This page covers a **native** Ploi site (nginx + PHP-FPM). For a Ploi **Docker**
server with Caddy in front, see [web-server-caddy.md](web-server-caddy.md).

## Contents

- [Shared `.env`](#shared-env)
- [Update `DB_*` settings](#update-db_-settings)
- [Laravel + Postgres notes](#laravel--postgres-notes)
- [Ploi Docker servers](#ploi-docker-servers)
- [Daemons](#daemons)

## Shared `.env`

The deploy script keeps the Laravel `.env` and `storage/` in
`/home/ploi/<site>-shared/` so they survive every zero-downtime release, and
symlinks them into each release.

Ploi's **Environment** editor reads `/home/ploi/<site>/.env`, so point that at
the shared file too (otherwise Ploi says ".env file not found"):

```sh
ln -sfn /home/ploi/<site>-shared/.env /home/ploi/<site>/.env
```

## Update `DB_*` settings

[`shell/web/update-env-db.sh`](../../shell/web/update-env-db.sh) backs up the
shared `.env` (`.env.bak.<timestamp>`), replaces only the `DB_*` keys you give
it (idempotent; other keys such as `DB_SSLMODE` stay), and prints the result
with `DB_PASSWORD=***`. Values come from a file or flags, never from the script.

```sh
# on the DB server: save the values (contains the password)
sudo /root/docker-db-server-manager.sh env | grep '^DB_' > ~/db.env
# copy it to your workstation (or write the file by hand from config/web-db.env.example)
scp <db-alias>:db.env ./db.env && ssh <db-alias> rm db.env

# from your workstation
shell/web/update-env-db.sh --remote <web-alias> --site <domain> --from db.env
rm db.env

# or, on the web server itself
update-env-db.sh --env /home/ploi/<site>-shared/.env --from db.env
update-env-db.sh --site <domain> --set DB_PORT=6432 --dry-run
```

Then **redeploy** in Ploi: config is cached at deploy time (`config:cache`).

## Laravel + Postgres notes

- PgBouncer must run in **session** mode (it does); transaction mode would
  need emulated prepares and other Laravel changes.
- Apps that create databases at runtime (`CREATE DATABASE`, e.g. multi-tenant packages) needs a **direct**
  Postgres connection on 5432 and a role with `CREATEDB`. Keep `DB_PORT=5432`
  unless a separate connection handles database provisioning.
- New databases inherit the extensions from `template1` (postgis, vector, ...).

## Ploi Docker servers

- On a Docker-type server, Ploi creates containers from a docker compose file
  in `/home/ploi/containers/<name>`, starts and stops them (`docker compose up`
  / `down`) and shows their logs. It runs compose files, **not** bash scripts,
  so it cannot run `docker-db-server-manager.sh`.
- Do not create a Ploi Docker application for the DB stack: the manager owns
  its compose project in `/opt/db` (project name `db`), and a second copy
  managed by Ploi would fight over containers, ports and volumes. Use a plain
  droplet for the DB server and run the manager over SSH.
- A Docker web server needs something in front of the app container for
  HTTP/TLS: Caddy, set up in [web-server-caddy.md](web-server-caddy.md).

## Daemons

Queue worker and scheduler: see [daemons.md](daemons.md).
