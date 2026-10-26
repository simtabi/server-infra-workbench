# simtabi/vps-hosting-management

[![CI](https://img.shields.io/github/actions/workflow/status/simtabi/vps-hosting-management/ci.yml?branch=main&label=ci)](https://github.com/simtabi/vps-hosting-management/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> Scripts and runbooks for hosting Laravel apps on DigitalOcean droplets managed
> with Ploi: a dedicated Docker database server on the private VPC, a Ploi web
> server, zero-downtime deploys, daemons and SSH access.

Everything is plain Bash plus docker compose. Every name, path, IP, port and
image version is a parameter with a default; project-specific values live only
in [`examples/`](examples).

## What's here

| Path | What |
|---|---|
| [`scripts/db/docker-db-server-manager.sh`](scripts/db/docker-db-server-manager.sh) | Docker DB Server Setup Manager: PostgreSQL 18 + PostGIS 3.6 + pgvector, PgBouncer (session, scram), MySQL 9.7, MariaDB 13, bound to the private IP. `install reset status verify env logs backup restore cron-install cron-remove uninstall help` |
| [`scripts/db/remote-run.sh`](scripts/db/remote-run.sh) | Run the manager on the DB server from your workstation, with a wrong-server guard |
| [`scripts/web/update-env-db.sh`](scripts/web/update-env-db.sh) | Back up a shared Laravel `.env` and replace its `DB_*` keys idempotently (password masked in output); local or `--remote` |
| [`scripts/deploy/ploi-deploy.sh`](scripts/deploy/ploi-deploy.sh) | Ploi zero-downtime deploy script for Laravel (preflight, shared storage/.env, first-run install, migrations, caches, queue restart) |
| [`compose/caddy`](compose/caddy) | Caddy reverse proxy compose example for a Ploi Docker web server |
| [`config/`](config) | `.env.example`-style templates for every script |
| [`tools/ploi-do-plan-finder`](tools/ploi-do-plan-finder) | List droplet plans/regions available through Ploi for your DO credentials |
| [`examples/myapp`](examples/myapp) | The reference deployment (no secrets) |

## Docs

1. [Architecture](docs/architecture.md): droplets, VPC, `eth0` vs `eth1`, where things live
2. [DB server](docs/db-server.md): runbook and full manager reference
3. [Web server (Ploi)](docs/web-server-ploi.md): shared `.env`, `DB_*` updates, Laravel/PgBouncer notes, Ploi Docker servers
4. [Deploy script](docs/deploy.md), including the Ploi placeholder caveat
5. [Daemons](docs/daemons.md): queue worker and scheduler in Supervisor
6. [SSH access](docs/ssh-access.md): sshmgr keys, Ploi, sudo, Termius
7. [Troubleshooting](docs/troubleshooting.md): real failures and fixes

## Quick start

```sh
# 0. SSH: one key per host (see docs/ssh-access.md), add the .pub in Ploi for user ploi
sshmgr host apply myproj prd-db-00 203.0.113.20 ploi db --reconcile
ssh prd-db-00 whoami                                  # -> ploi

# 1. Config for the DB server (no secrets in it)
cp config/db-server.env.example my-db-server.conf     # set EXPECTED_PRIVATE_IP, VPC_CIDR, PG_USER ...

# 2. From your workstation: install + guard + backups + DB_* lines
scripts/db/remote-run.sh --host prd-db-00 --expect-ip 10.0.0.5 \
  --config my-db-server.conf -- install, cron-install, env

# 3. Put the DB_* lines on the web server, then redeploy in Ploi
scripts/web/update-env-db.sh --remote prd-web-00 --site example.com --from db.env
```

## Development

```sh
make help     # targets
make lint     # shellcheck + bash -n on every script
make test     # offline smoke tests
make ci       # what CI runs
```

Requires bash 4+, [shellcheck](https://www.shellcheck.net/) and (for the
compose checks) docker.

## License

[MIT](LICENSE)
