# Examples

Generic, made-up examples only (`example.com`, `db-01`/`web-01`, `10.0.0.5`, documentation IPs
`203.0.113.x`). Real deployments belong in [`local/`](../local/README.md), which git ignores, so no
client hosts, IPs, domains or names ever reach the repository. `make client-check` enforces that.

**No passwords here, ever.** Every password, token and key is generated on the server at install time
(`openssl rand`, written to a 600 file) or read from your credentials file. Examples hold settings only.

## Run one (offline, writes nothing)

```bash
examples/run.sh split-web-db-vpc     # configure --dry-run with the example's settings + the tool plans
examples/run.sh --all                # every runnable example (part of `make test`)
```

Each runnable example has an `example.conf`: the profile, `set KEY=VALUE` overrides and read-only
`plan` commands. `run.sh` runs `bin/workbench configure --profile P --set ... --dry-run`, so the same
checks as a real configure run (RAM per node, TLS on prd, alerts, VPC ranges).
`run.sh` also runs each example's `selftest <script>` lines (`<script> --self-test`, offline, throwaway files),
checks a `ploi-deploy.settings.sh` against the deploy script (`_shared/ploi-script.sh --check`), and scans every
file for hardcoded secrets. To use one for real:
`bin/workbench configure --profile <PROFILE> --client <you> --set ...` (files go to `local/<you>/`).

## Catalog

Status: **available** = folder with a README and a runnable `example.conf` (every entry is available).
Shared scripts and snippets live in [`_shared/`](_shared/README.md). Profiles: [profiles reference](../docs/reference/profiles.md).

### Laravel apps

| Example | What | Profile | Add-ons / settings | Status |
|---|---|---|---|---|
| [generic-laravel](generic-laravel/README.md) | Postgres-only DB server, zero-downtime Ploi site | `dev-budget` | none | available |
| [laravel-multitenant](laravel-multitenant/README.md) | landlord DB per env, tenant DBs created at runtime (`<app>_<env>_t_<id>`) | `dev-budget` | `TENANT_ENVS`, `PG_APP_CREATEDB=1` | available |
| [laravel-horizon-reverb](laravel-horizon-reverb/README.md) | queues with Horizon + Reverb websockets as daemons | `production-single` | [run-daemons recipe](../docs/recipes/run-daemons.md) | available |
| [laravel-octane](laravel-octane/README.md) | Octane (FrankenPHP/Swoole) behind Nginx on Ploi | `production-single` | `WEB_DROPLET_MB=4096` | available |
| [mysql-app](mysql-app/README.md) | a Laravel app on MySQL instead of Postgres | `mysql-app` | `ENABLE_MYSQL=1` | available |
| [gotenberg](gotenberg/README.md) | HTML/Office to PDF service next to the app, loopback only | `dev-budget` | `GOTENBERG=1`, `GOTENBERG_ROLE=web` | available |

### Other stacks (same DB server, different web tier)

| Example | What | Profile | Notes | Status |
|---|---|---|---|---|
| [wordpress](wordpress/README.md) | WordPress on MySQL/MariaDB | `mysql-app` | Ploi site type WordPress | available |
| [symfony](symfony/README.md) | Symfony app on Postgres | `dev-budget` | `DATABASE_URL` without a password, `PGPASSFILE` | available |
| [node-nextjs](node-nextjs/README.md) | Next.js (SSR) as a daemon behind Nginx | `dev-budget` | daemon recipe | available |
| [nestjs](nestjs/README.md) | NestJS API on Postgres | `dev-budget` | daemon recipe | available |
| [django](django/README.md) | Django + Gunicorn on Postgres | `dev-budget` | daemon recipe | available |
| [fastapi](fastapi/README.md) | FastAPI + Uvicorn on Postgres | `dev-budget` | daemon recipe | available |
| [rails](rails/README.md) | Rails + Puma on Postgres | `dev-budget` | daemon recipe | available |
| [go-api](go-api/README.md) | a Go binary API on Postgres | `dev-budget` | systemd unit | available |
| [static-site-caddy](static-site-caddy/README.md) | a static site behind the repo's Caddy stack | `dev-budget` | [stacks/caddy](../stacks/caddy) | available |
| [ploi-managed-site](ploi-managed-site/README.md) | any Ploi site using the deploy script only | `dev-budget` | [Ploi recipe](../docs/recipes/configure-a-ploi-web-server.md) | available |

### Topology

| Example | What | Profile | Settings | Status |
|---|---|---|---|---|
| [single-droplet-all-in-one](single-droplet-all-in-one/README.md) | web + DB on one budget droplet (dev only) | `dev-budget` | `ENVS=dev`, `DB_PRIVATE_IP` = `WEB_PRIVATE_IP` | available |
| [split-web-db-vpc](split-web-db-vpc/README.md) | web droplet + DB droplet, same region, VPC only | `production-single` | `DB_PRIVATE_IP`, `WEB_PRIVATE_IP`, `VPC_CIDR` | available |
| [cross-region-wireguard](cross-region-wireguard/README.md) | web and DB in different regions over WireGuard | `cross-region-wireguard` | `WIREGUARD=1`, `PEER_REGION` | available |
| [managed-postgres-prd](managed-postgres-prd/README.md) | prd on DO Managed Postgres with a standby, two web nodes, Spaces | `production-ha` | `DB_MODE=managed` | available |
| [multi-engine-migration](multi-engine-migration/README.md) | Postgres, MySQL and MariaDB side by side while an app moves engines | `multi-engine` | `ENABLE_MYSQL=1`, `ENABLE_MARIADB=1` | available |
| [ha-two-web-lb](ha-two-web-lb/README.md) | load balancer + 2 web nodes + managed DB | `production-ha` | `WEB_NODES=2`, `LOAD_BALANCER=1` | available |
| [gcp-vm](gcp-vm/README.md) | the same layout on a GCP VM | `production-single` | `bin/workbench gcp` | available |

### Services, monitoring, backups, DNS

| Example | What | Profile | Add-ons / settings | Status |
|---|---|---|---|---|
| [s3-storage](s3-storage/README.md) | self-hosted S3 (Garage; SeaweedFS or RustFS as alternatives) | `dev-budget` | `STORAGE=garage`, `STORAGE_ROLE=db` | available |
| [monitoring](monitoring/README.md) | Beszel + Uptime Kuma hub; Prometheus + Grafana as the upgrade | `staging` | `MONITOR_STACKS`, `MONITOR_HUB` | available |
| [backups-pitr-spaces](backups-pitr-spaces/README.md) | nightly dumps + pgBackRest PITR to DO Spaces | `production-single` | `PITR=pgbackrest`, `OFFSITE=s3` | available |
| [cloudflare-dns-proxy](cloudflare-dns-proxy/README.md) | DNS records and proxy through Cloudflare | `dev-budget` | `bin/workbench cf` | available |

New project: `cp -R examples/<one> local/<yourproject>` and follow
[docs/getting-started.md](../docs/getting-started.md).
