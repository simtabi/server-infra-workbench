# Documentation

| # | Page | Read it when |
|---|---|---|
| 0 | [New project in 10 minutes](guides/getting-started.md) | starting a new project with this toolkit |
| 1 | [Architecture](reference/architecture.md) | first: droplets, VPC, `eth0` vs `eth1`, ports, where files live |
| 2 | [SSH access](guides/ssh-access.md) | setting up keys, sudo, Termius; "which machine am I on?" |
| 3 | [DB server](reference/db-server.md) | building, checking, backing up the database droplet |
| 4 | [Upgrading an existing DB server](guides/upgrading.md) | a server set up with an earlier version of the manager |
| 5 | [Web server (Ploi, native)](guides/web-server-ploi.md) | shared `.env`, `DB_*` updates, Laravel + Postgres notes |
| 6 | [Web server with Caddy (Ploi Docker)](guides/web-server-caddy.md) | running the app in containers behind Caddy with automatic HTTPS |
| 7 | [Deploy script](guides/deploy.md) | native Ploi zero-downtime deploys, first run |
| 8 | [Daemons](guides/daemons.md) | queue worker and scheduler under Supervisor |
| 9 | [Troubleshooting](guides/troubleshooting.md) | something failed; real errors and their fixes |
| 10 | [Security and operations](reference/security.md) | firewall, Docker vs ufw, updates, logs, monitoring |
| 11 | [Status](reference/status.md) | what's done and what's still open |
| 12 | [Connections](guides/connections.md) | TablePlus/psql over SSH, web to DB, Adminer UI, Redis, backups off-site, deploy key, mail, MongoDB |
| 13 | [Rollout plan](runbooks/rollout-plan.md) | applying a new manager version (users, PgBouncer auth, Adminer) to a live server |

## Diagrams

| Diagram | Page |
|---|---|
| System overview | [architecture.md](reference/architecture.md#overview-diagram) |
| Request flow (sequence) | [architecture.md](reference/architecture.md#request-flow) |
| Caddy stack | [web-server-caddy.md](guides/web-server-caddy.md#how-it-fits-together) |
| Deploy pipeline with first-run branches | [deploy.md](guides/deploy.md#pipeline) |
| DB manager command lifecycle | [db-server.md](reference/db-server.md#4-commands) |
| Backup and restore | [db-server.md](reference/db-server.md#backup) |
| Upgrade procedure | [upgrading.md](guides/upgrading.md#steps-from-your-workstation) |
| SSH key flow | [ssh-access.md](guides/ssh-access.md#key-flow) |
| Which machine am I on? | [ssh-access.md](guides/ssh-access.md#which-machine-am-i-on) |
| All connections (Mac, web, DB, off-site) | [connections.md](guides/connections.md#overview) |

Diagrams are [Mermaid](https://mermaid.js.org); GitHub renders them inline.

## Command reference

| Script | Runs on | Main commands / flags |
|---|---|---|
| [`docker-db-server-manager.sh`](../shell/db/docker-db-server-manager.sh) | DB server (root) | `init install reset status verify doctor env create-db create-user grant rotate-password list-dbs list-users drop-db drop-user backup restore cron-install cron-remove logs uninstall help`; `--yes --config --version` |
| [`remote-run.sh`](../shell/db/remote-run.sh) | workstation | `--host --expect-ip --config --script --no-upload --dry-run -- <cmd>, <cmd>` |
| [`update-env-db.sh`](../shell/web/update-env-db.sh) | web server or workstation | `--env --site --from --set --remote --no-backup --dry-run` |
| [`check-db-reach.sh`](../shell/web/check-db-reach.sh) | web server or workstation | `<db-ip> [ports]`, `--env FILE`, `--remote ALIAS` |
| [`db-tunnel.sh`](../shell/tunnels/db-tunnel.sh) | workstation | `<postgres|pgbouncer|mysql|mariadb|adminer|all> --host --private-ip --background --print` |
| [`ploi-deploy.sh`](../shell/deploy/ploi-deploy.sh) | pasted into Ploi | SETTINGS block, see [deploy.md](guides/deploy.md#settings) |
| [`stacks/caddy`](../stacks/caddy) | Docker web server | `docker compose up -d`, `caddy reload`, see [web-server-caddy.md](guides/web-server-caddy.md#day-2-reload-logs-upgrades) |
