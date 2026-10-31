# Documentation

New here? Read [Installation](installation.md), then [Getting started](getting-started.md) (a new project in
10 minutes), then [Architecture](architecture.md).

## Guides

| Page | Read it when |
|---|---|
| [Installation](installation.md) | setting up a workstation: requirements, Composer, credentials check |
| [Getting started](getting-started.md) | starting a new project: two droplets to a deployed app |
| [Configuration](configuration.md) | config files, precedence, platform credentials, what is written where |
| [Architecture](architecture.md) | droplets, VPC, `eth0` vs `eth1`, ports, where files live |
| [Repository structure](structure.md) | where things are, where new things go, old to new paths |
| [Security and operations](security.md) | firewall, Docker vs ufw, updates, logs, monitoring |
| [Troubleshooting](troubleshooting.md) | something failed: real errors and their fixes |
| [Status](status.md) | what is done and what is still open |
| [Releasing](release.md) | versioning and the release checklist |

## Tools (reference)

| Page | Tool |
|---|---|
| [DB server manager](tools/db-server-manager.md) | `shell/db/docker-db-server-manager.sh` and `remote-run.sh`: build, check, back up, upgrade the database droplet |
| [Deploy script](tools/deploy-script.md) | `shell/deploy/ploi-deploy.sh`: zero-downtime Ploi deploys, presets, hooks, first run |
| [Caddy stack](tools/caddy-stack.md) | `stacks/caddy`: the app in containers behind Caddy with automatic HTTPS |
| [Command line](tools/cli.md) | `bin/workbench`: one entry point, platform commands, flags, exit codes |
| [Platform API library](tools/platform-api.md) | `php/`: DigitalOcean, Cloudflare, Ploi, GCP clients, pending actions, audit log |
| [Python package](tools/python.md) | `python/`: small helpers (`ping`) |

## Recipes

| Recipe | When |
|---|---|
| [Set up SSH access](recipes/set-up-ssh-access.md) | keys, sudo, Termius; "which machine am I on?" |
| [Configure a Ploi web server](recipes/configure-a-ploi-web-server.md) | shared `.env`, `DB_*` updates, Laravel + Postgres notes |
| [Run daemons](recipes/run-daemons.md) | queue worker and scheduler under Supervisor |
| [Connect to databases](recipes/connect-to-databases.md) | TablePlus/psql over SSH, web to DB, Adminer, Redis, off-site backups, deploy key, mail, MongoDB |
| [Upgrade a legacy DB server](recipes/upgrade-a-legacy-db-server.md) | a server set up with an earlier version of the manager |
| [Roll out a manager upgrade](recipes/roll-out-a-manager-upgrade.md) | applying a new manager version to a live server with `upgrade` |

## Decisions

[Architecture decision records](adr/README.md): layout, PHP on PSR-18, pending actions, credentials.

## Diagrams

| Diagram | Page |
|---|---|
| System overview | [architecture.md](architecture.md#overview-diagram) |
| Request flow (sequence) | [architecture.md](architecture.md#request-flow) |
| Caddy stack | [caddy-stack.md](tools/caddy-stack.md#how-it-fits-together) |
| Deploy pipeline with first-run branches | [deploy-script.md](tools/deploy-script.md#pipeline) |
| DB manager command lifecycle | [db-server-manager.md](tools/db-server-manager.md#4-commands) |
| Backup and restore | [db-server-manager.md](tools/db-server-manager.md#backup) |
| Guided upgrade | [roll-out-a-manager-upgrade.md](recipes/roll-out-a-manager-upgrade.md) |
| Legacy upgrade procedure | [upgrade-a-legacy-db-server.md](recipes/upgrade-a-legacy-db-server.md#steps-from-your-workstation) |
| SSH key flow | [set-up-ssh-access.md](recipes/set-up-ssh-access.md#key-flow) |
| Which machine am I on? | [set-up-ssh-access.md](recipes/set-up-ssh-access.md#which-machine-am-i-on) |
| All connections (Mac, web, DB, off-site) | [connect-to-databases.md](recipes/connect-to-databases.md#overview) |

Diagrams are [Mermaid](https://mermaid.js.org); GitHub renders them inline; `make mermaid` renders them all.

## Command reference

| Tool | Runs on | Main commands / flags |
|---|---|---|
| [`bin/workbench`](../bin/workbench) | workstation | `list`, `<area> <tool>`, `do`, `cf`, `ploi`, `gcp`, `credentials`, `py`; `--dry-run --yes --force --json --verbose`, see [cli.md](tools/cli.md) |
| [`docker-db-server-manager.sh`](../shell/db/docker-db-server-manager.sh) | DB server (root) | `init install upgrade reset status verify doctor env create-db create-user grant rotate-password list-dbs list-users drop-db drop-user backup restore cron-install cron-remove logs uninstall help`; `--yes --dry-run --non-interactive --snapshot --snapshot-taken --no-snapshot --config --version` |
| [`remote-run.sh`](../shell/db/remote-run.sh) | workstation | `--host --expect-ip --config --script --no-upload --dry-run -- <cmd>, <cmd>` |
| [`update-env-db.sh`](../shell/web/update-env-db.sh) | web server or workstation | `--env --site --from --set --remote --no-backup --dry-run` |
| [`check-db-reach.sh`](../shell/web/check-db-reach.sh) | web server or workstation | `<db-ip> [ports]`, `--env FILE`, `--remote ALIAS` |
| [`db-tunnel.sh`](../shell/tunnels/db-tunnel.sh) | workstation | `<postgres\|pgbouncer\|mysql\|mariadb\|adminer\|all> --host --private-ip --background --print` |
| [`ploi-deploy.sh`](../shell/deploy/ploi-deploy.sh) | pasted into Ploi | SETTINGS block, see [deploy-script.md](tools/deploy-script.md#settings) |
| [`stacks/caddy`](../stacks/caddy) | Docker web server | `docker compose up -d`, `caddy reload`, see [caddy-stack.md](tools/caddy-stack.md#day-2-reload-logs-upgrades) |
