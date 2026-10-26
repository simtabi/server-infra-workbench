# Documentation

| # | Page | Read it when |
|---|---|---|
| 1 | [Architecture](architecture.md) | first: droplets, VPC, `eth0` vs `eth1`, ports, where files live |
| 2 | [SSH access](ssh-access.md) | setting up keys, sudo, Termius; "which machine am I on?" |
| 3 | [DB server](db-server.md) | building, checking, backing up the database droplet |
| 4 | [Upgrading an existing DB server](upgrading.md) | a server set up with the earlier script (myapp) |
| 5 | [Web server (Ploi, native)](web-server-ploi.md) | shared `.env`, `DB_*` updates, Laravel + Postgres notes |
| 6 | [Web server with Caddy (Ploi Docker)](web-server-caddy.md) | running the app in containers behind Caddy with automatic HTTPS |
| 7 | [Deploy script](deploy.md) | native Ploi zero-downtime deploys, first run |
| 8 | [Daemons](daemons.md) | queue worker and scheduler under Supervisor |
| 9 | [Troubleshooting](troubleshooting.md) | something failed; real errors and their fixes |

## Diagrams

| Diagram | Page |
|---|---|
| System overview | [architecture.md](architecture.md#overview-diagram) |
| Request flow (sequence) | [architecture.md](architecture.md#request-flow) |
| Caddy stack | [web-server-caddy.md](web-server-caddy.md#how-it-fits-together) |
| Deploy pipeline with first-run branches | [deploy.md](deploy.md#pipeline) |
| DB manager command lifecycle | [db-server.md](db-server.md#4-commands) |
| Backup and restore | [db-server.md](db-server.md#backup) |
| Upgrade procedure | [upgrading.md](upgrading.md#steps-from-your-workstation) |
| SSH key flow | [ssh-access.md](ssh-access.md#key-flow) |
| Which machine am I on? | [ssh-access.md](ssh-access.md#which-machine-am-i-on) |

Diagrams are [Mermaid](https://mermaid.js.org); GitHub renders them inline.

## Command reference

| Script | Runs on | Main commands / flags |
|---|---|---|
| [`docker-db-server-manager.sh`](../scripts/db/docker-db-server-manager.sh) | DB server (root) | `install reset status verify env backup restore cron-install cron-remove logs uninstall help`; `--yes --config --version` |
| [`remote-run.sh`](../scripts/db/remote-run.sh) | workstation | `--host --expect-ip --config --script --no-upload --dry-run -- <cmd>, <cmd>` |
| [`update-env-db.sh`](../scripts/web/update-env-db.sh) | web server or workstation | `--env --site --from --set --remote --no-backup --dry-run` |
| [`ploi-deploy.sh`](../scripts/deploy/ploi-deploy.sh) | pasted into Ploi | SETTINGS block, see [deploy.md](deploy.md#settings) |
| [`compose/caddy`](../compose/caddy) | Docker web server | `docker compose up -d`, `caddy reload`, see [web-server-caddy.md](web-server-caddy.md#day-2-reload-logs-upgrades) |
