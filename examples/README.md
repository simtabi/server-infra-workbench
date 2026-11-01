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
checks as a real configure run (RAM per node, TLS on prd, alerts, VPC ranges). To use one for real:
`bin/workbench configure --profile <PROFILE> --client <you> --set ...` (files go to `local/<you>/`).

## Catalog

Status: **available** = folder with a README and a runnable `example.conf`; **planned** = not written yet
(the profile and tools already cover it unless noted). Profiles: [profiles reference](../docs/reference/profiles.md).

### Laravel apps

| Example | What | Profile | Add-ons / settings | Status |
|---|---|---|---|---|
| [generic-laravel](generic-laravel/README.md) | Postgres-only DB server, zero-downtime Ploi site | `dev-budget` | none | available |
| [laravel-multitenant](laravel-multitenant/README.md) | landlord DB per env, tenant DBs created at runtime (`<app>_<env>_t_<id>`) | `dev-budget` | `TENANT_ENVS`, `PG_APP_CREATEDB=1` | available |
| laravel-horizon-reverb | queues with Horizon + Reverb websockets as daemons | `production-single` | [run-daemons recipe](../docs/recipes/run-daemons.md) | planned |
| laravel-octane | Octane (FrankenPHP/Swoole) behind Nginx on Ploi | `production-single` | `WEB_DROPLET_MB=4096` | planned |
| [mysql-app](mysql-app/README.md) | a Laravel app on MySQL instead of Postgres | `mysql-app` | `ENABLE_MYSQL=1` | available |
| [gotenberg](gotenberg/README.md) | HTML/Office to PDF service next to the app, loopback only | `dev-budget` | `GOTENBERG=1`, `GOTENBERG_ROLE=web` | available |

### Other stacks (same DB server, different web tier)

| Example | What | Profile | Notes | Status |
|---|---|---|---|---|
| wordpress | WordPress on MySQL/MariaDB | `mysql-app` | Ploi site type WordPress | planned |
| symfony | Symfony app on Postgres | `dev-budget` | `DATABASE_URL` without a password, `PGPASSFILE` | planned |
| node-nextjs | Next.js (SSR) as a daemon behind Nginx | `dev-budget` | daemon recipe | planned |
| nestjs | NestJS API on Postgres | `dev-budget` | daemon recipe | planned |
| django | Django + Gunicorn on Postgres | `dev-budget` | daemon recipe | planned |
| fastapi | FastAPI + Uvicorn on Postgres | `dev-budget` | daemon recipe | planned |
| rails | Rails + Puma on Postgres | `dev-budget` | daemon recipe | planned |
| go-api | a Go binary API on Postgres | `dev-budget` | systemd unit | planned |
| static-site-caddy | a static site behind the repo's Caddy stack | none | [stacks/caddy](../stacks/caddy) | planned |
| ploi-managed-site | any Ploi site using the deploy script only | none | [Ploi recipe](../docs/recipes/configure-a-ploi-web-server.md) | planned |

### Topology

| Example | What | Profile | Settings | Status |
|---|---|---|---|---|
| single-droplet-all-in-one | web + DB on one budget droplet (dev only) | `dev-budget` | `PRD_LOCATION=local` | planned |
| [split-web-db-vpc](split-web-db-vpc/README.md) | web droplet + DB droplet, same region, VPC only | `production-single` | `DB_PRIVATE_IP`, `WEB_PRIVATE_IP`, `VPC_CIDR` | available |
| [cross-region-wireguard](cross-region-wireguard/README.md) | web and DB in different regions over WireGuard | `cross-region-wireguard` | `WIREGUARD=1`, `PEER_REGION` | available |
| [managed-postgres-prd](managed-postgres-prd/README.md) | prd on DO Managed Postgres with a standby, two web nodes, Spaces | `production-ha` | `DB_MODE=managed` | available |
| [multi-engine-migration](multi-engine-migration/README.md) | Postgres, MySQL and MariaDB side by side while an app moves engines | `multi-engine` | `ENABLE_MYSQL=1`, `ENABLE_MARIADB=1` | available |
| ha-two-web-lb | load balancer + 2 web nodes + managed DB | `production-ha` | `WEB_NODES=2`, `LOAD_BALANCER=1` | planned |
| gcp-vm | the same layout on a GCP VM | any | `bin/workbench gcp` | planned |

### Services, monitoring, backups, DNS

| Example | What | Profile | Add-ons / settings | Status |
|---|---|---|---|---|
| [s3-storage](s3-storage/README.md) | self-hosted S3 (Garage; SeaweedFS or RustFS as alternatives) | `dev-budget` | `STORAGE=garage`, `STORAGE_ROLE=db` | available |
| [monitoring](monitoring/README.md) | Beszel + Uptime Kuma hub; Prometheus + Grafana as the upgrade | `staging` | `MONITOR_STACKS`, `MONITOR_HUB` | available |
| backups-pitr-spaces | nightly dumps + pgBackRest PITR to DO Spaces | `production-single` | `PITR=pgbackrest`, `OFFSITE=s3` | planned |
| cloudflare-dns-proxy | DNS records and proxy through Cloudflare | any | `bin/workbench cf` | planned |

New project: `cp -R examples/<one> local/<yourproject>` and follow
[docs/getting-started.md](../docs/getting-started.md).
