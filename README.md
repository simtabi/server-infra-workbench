# simtabi/vps-server-workbench

[![CI](https://img.shields.io/github/actions/workflow/status/simtabi/vps-server-workbench/ci.yml?branch=main&label=ci)](https://github.com/simtabi/vps-server-workbench/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> Scripts and runbooks for hosting PHP (Laravel or not) apps on DigitalOcean droplets managed
> with Ploi: a dedicated Docker database server on the private VPC, a Ploi web
> server, zero-downtime deploys, daemons and SSH access.

Everything is plain Bash plus docker compose. Every name, path, IP, port and
image version is a parameter with a default; project-specific values live only
in [`examples/`](examples).

## What's here

| Path | What |
|---|---|
| [`shell/db/docker-db-server-manager.sh`](shell/db/docker-db-server-manager.sh) | Docker DB Server Setup Manager: PostgreSQL 18 + PostGIS 3.6 + pgvector, PgBouncer (session, scram), MySQL 9.7, MariaDB 13, bound to the private IP. each engine optional. `init install reset status verify doctor env create-db create-user grant rotate-password list-dbs list-users drop-db drop-user logs backup restore cron-install cron-remove uninstall help` |
| [`shell/db/remote-run.sh`](shell/db/remote-run.sh) | Run the manager on the DB server from your workstation, with a wrong-server guard |
| [`shell/web/update-env-db.sh`](shell/web/update-env-db.sh) | Back up a shared Laravel `.env` and replace its `DB_*` keys idempotently (password masked in output); local or `--remote` |
| [`shell/deploy/ploi-deploy.sh`](shell/deploy/ploi-deploy.sh) | Ploi deploy script for any PHP/Node app: `laravel` or `generic` preset, optional hooks (first install, migrations, post-deploy, health check), zero-downtime or in-place |
| [`shell/tunnels/db-tunnel.sh`](shell/tunnels/db-tunnel.sh) | SSH tunnels from the Mac per engine (`postgres pgbouncer mysql mariadb adminer all`) for TablePlus, psql, Adminer |
| [`shell/web/check-db-reach.sh`](shell/web/check-db-reach.sh) | TCP check from the web server to every DB port (no passwords needed) |
| [`stacks/caddy`](stacks/caddy) | Laravel (php-fpm, queue, scheduler) behind Caddy with automatic HTTPS, for a Ploi Docker web server; reverse-proxy and smoke-test variants |
| [`config/`](config) | `.env.example`-style templates for every script |
| [`tools/ploi-do-plan-finder`](tools/ploi-do-plan-finder) | List droplet plans/regions available through Ploi for your DO credentials |
| [`examples/`](examples/README.md) | Example configs per project (no secrets): a made-up generic Laravel app and a real deployment |

## Docs

Start at the [docs index](docs/README.md) (diagrams and command reference included), or go straight to
**[New project in 10 minutes](docs/guides/getting-started.md)**.

1. [Architecture](docs/reference/architecture.md): droplets, VPC, `eth0` vs `eth1`, ports, where things live
2. [SSH access](docs/guides/ssh-access.md): sshmgr keys, Ploi, sudo, Termius
3. [DB server](docs/reference/db-server.md): runbook and full manager reference
4. [Upgrading an existing DB server](docs/guides/upgrading.md): install the config first, no `reset`
5. [Web server (Ploi, native)](docs/guides/web-server-ploi.md): shared `.env`, `DB_*` updates, Laravel/PgBouncer notes
6. [Web server with Caddy (Ploi Docker)](docs/guides/web-server-caddy.md): install, Caddyfile, DNS, HTTPS, staging/prod
7. [Deploy script](docs/guides/deploy.md), including the Ploi placeholder caveat
8. [Daemons](docs/guides/daemons.md): queue worker and scheduler in Supervisor
- [Connections](docs/guides/connections.md): TablePlus/psql over SSH, Adminer, web to DB, Redis, off-site backups, mail, MongoDB verdict
- [Rollout plan](docs/runbooks/rollout-plan.md): apply a new manager version to a live server safely
9. [Troubleshooting](docs/guides/troubleshooting.md): real failures and fixes
10. [Security and operations](docs/reference/security.md) and [status](docs/reference/status.md)

## Quick start

```sh
# 0. SSH: one key per host (see docs/guides/ssh-access.md), add the .pub in Ploi for user ploi
sshmgr host apply myproject prd-db-00 203.0.113.20 ploi db --reconcile
ssh prd-db-00 whoami                                  # -> ploi

# 1. Config for the DB server (no secrets in it): detects the private IP and VPC
ssh prd-db-00 'bash -s -- init' < shell/db/docker-db-server-manager.sh > my-db-server.conf
#    edit PG_USER / ENABLE_* ... (or start from config/db-server.env.example)

# 2. From your workstation: install + guard + backups + DB_* lines
shell/db/remote-run.sh --host prd-db-00 --expect-ip 10.0.0.5 \
  --config my-db-server.conf -- install, cron-install, env

# 3. Save the printed DB_* lines as db.env (never commit it), put them on the web server, redeploy
shell/web/update-env-db.sh --remote prd-web-00 --site example.com --from db.env
```

## Development

```sh
make help     # targets
make lint     # shellcheck + bash -n on every script
make test     # offline smoke tests
make links    # check relative links and #anchors in all Markdown
make compose-check  # docker compose config + caddy validate
make ci       # all of the above (what CI runs)
```

Requires bash 4+ (`update-env-db.sh` also runs on macOS bash 3.2), python3,
[shellcheck](https://www.shellcheck.net/) and (for the compose checks) docker.

## License

[MIT](LICENSE)
