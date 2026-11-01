# Documentation

New here? Read [Installation](installation.md), then [Getting started](getting-started.md) (a new project in
10 minutes), then [Architecture](architecture.md).

## Guides

| Page | Read it when |
|---|---|
| [Installation](installation.md) | setting up a workstation: requirements, Composer, credentials check |
| [Getting started](getting-started.md) | starting a new project: two droplets to a deployed app |
| [Ploi + DigitalOcean setup](guides/ploi-digitalocean-setup.md) | the whole flow end to end: droplets, VPC, firewall, Ploi site settings, siwo DB server, daemons, Cloudflare DNS and wildcard certificates, real troubleshooting |
| [Configure a setup](configure.md) | picking a profile and generating a client's config with `bin/siwo configure` |
| [Configuration](configuration.md) | config files, precedence, platform credentials, what is written where |
| [Architecture](architecture.md) | droplets, VPC, `eth0` vs `eth1`, ports, where files live |
| [Repository structure](structure.md) | where things are, where new things go, old to new paths |
| [Database users and privileges](databases/users-and-privileges.md) | how databases, owners, master and read-only logins are created and linked; `admin-creds`; turning engines on/off without downtime |
| [Connecting local DB clients](databases/connecting-local-clients.md) | TablePlus, DBeaver, DataGrip/PhpStorm, psql/mysql over an SSH tunnel; ports and which login to use |
| [Database environments](database-environments.md) | one app, several environments (tst/dev/stg/prd): isolation, topologies, set-up flow, guard rails |
| [Backups and recovery](backups-and-recovery.md) | backup layers, retention, off-site, PITR, restore tests, which restore to use |
| [Servers in different regions](cross-region.md) | web and DB in different regions: same region, VPC peering, WireGuard, public TLS, managed DB |
| [High availability](high-availability.md) | removing single points of failure: managed prd, standby, two web nodes |
| [Checklists](checklists/README.md) | new DB/web server, manager upgrade, pre-launch, monthly restore drill |
| [Lessons learned](lessons-learned.md) | mistakes already made once and the rule each one produced |
| [Security and operations](security.md) | firewall, Docker vs ufw, updates, logs, monitoring |
| [Troubleshooting](troubleshooting.md) | something failed: real errors and their fixes |
| [Status](status.md) | what is done and what is still open |
| [Releasing](release.md) | versioning and the release checklist |

## Examples

[Examples catalog](../examples/README.md): every example by category with its profile, add-ons and status
(available or planned). Run one offline: `examples/run.sh <name>`.

## Tools (reference)

| Page | Tool |
|---|---|
| [remote-run](tools/remote-run.md) | `src/shell/db/remote-run.sh`: run manager commands on the DB server from the workstation; root `.env` settings, sudo, troubleshooting |
| [DB server manager](tools/db-server-manager.md) | `src/shell/db/docker-db-server-manager.sh` and `remote-run.sh`: build, check, back up, upgrade the database droplet |
| [Deploy script](tools/deploy-script.md) | `src/shell/deploy/ploi-deploy.sh`: zero-downtime Ploi deploys, presets, hooks, first run |
| [Server tools](tools/server.md) | `src/shell/server/*` and `web/diagnose.sh`: harden, update with a reboot window, diagnose a Laravel site (plan, confirm, audit) |
| [SSH keys](tools/ssh-keys.md) | `siwo keys` (provider accounts, servers) and `fixkeys.sh` console recovery; migration from vps-ssh-key-manager |
| [Networking](tools/net.md) | `src/shell/net/wireguard.sh`: WireGuard tunnel between two servers (keys stay on the servers, peer-only ufw) |
| [Laravel .env](tools/env.md) | `src/shell/env/env.sh`: `env init` (defaults, APP_KEY, validation, key-only diff, 600) and `env check` |
| [Add-ons](tools/addons.md) | `src/shell/addons/addon.sh` + `stacks/addons`: Gotenberg and one object store (Garage, SeaweedFS, RustFS) per node |
| [Caddy stack](tools/caddy-stack.md) | `stacks/caddy`: the app in containers behind Caddy with automatic HTTPS |
| [Command line](tools/cli.md) | `bin/siwo`: one entry point, platform commands, flags, exit codes |
| [Platform API library](tools/platform-api.md) | `src/php`: DigitalOcean, Cloudflare, Ploi, GCP, GitHub clients, pending actions, audit log |
| [Providers](providers/README.md) | Per provider: why, least-privilege token, every command, checklist, lessons learned |
| [Python package](tools/python.md) | `src/python`: `ping` probe and the `plans` finder (DO plans per region via Ploi) |

## Reference

| Page | What |
|---|---|
| [Profiles](reference/profiles.md) | the 7 setup profiles, every setting, what each profile changes, RAM estimates |
| [Privileges](reference/privileges.md) | which role can do what, per engine, and how to check |
| [Naming](reference/naming.md) | database, role, tenant and trash names; environments; reserved names |
| [Sizing](reference/sizing.md) | RAM per engine, droplet sizes per combination, the RAM warning |
| [Configuration keys](reference/configuration-keys.md) | every DB manager config key with its default (generated from the example config) |

## Recipes

| Recipe | When |
|---|---|
| [Recover from an SSH lockout](recipes/recover-ssh-lockout.md) | provider console, `fixkeys.sh` diagnose/add/perms/restore, recovery ISO |
| [Set up SSH access](recipes/set-up-ssh-access.md) | keys, sudo, Termius; "which machine am I on?" |
| [Configure a Ploi web server](recipes/configure-a-ploi-web-server.md) | shared `.env`, `DB_*` updates, Laravel + Postgres notes |
| [Run daemons](recipes/run-daemons.md) | queue worker and scheduler under Supervisor |
| [Connect to databases](recipes/connect-to-databases.md) | every connection path (clients: [Connecting local DB clients](databases/connecting-local-clients.md)), web to DB, Adminer, Redis, off-site backups, deploy key, mail, MongoDB |
| [Upgrade a legacy DB server](recipes/upgrade-a-legacy-db-server.md) | a server set up with an earlier version of the manager |
| [Roll out a manager upgrade](recipes/roll-out-a-manager-upgrade.md) | applying a new manager version to a live server with `upgrade` |

## Decisions

[Architecture decision records](adr/README.md): layout, PHP on PSR-18, pending actions, credentials, object storage,
database topology ([0008](adr/0008-database-topology.md)), MongoDB off by default ([0009](adr/0009-mongodb-off-by-default.md)),
least-privilege roles ([0010](adr/0010-least-privilege-database-roles.md)).

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
| Environment isolation and topologies | [database-environments.md](database-environments.md#how-isolation-works) |
| Backup layers and restore decisions | [backups-and-recovery.md](backups-and-recovery.md#layers) |
| Production HA | [high-availability.md](high-availability.md) |
| Legacy upgrade procedure | [upgrade-a-legacy-db-server.md](recipes/upgrade-a-legacy-db-server.md#steps-from-your-workstation) |
| SSH key flow | [set-up-ssh-access.md](recipes/set-up-ssh-access.md#key-flow) |
| Which machine am I on? | [set-up-ssh-access.md](recipes/set-up-ssh-access.md#which-machine-am-i-on) |
| All connections (Mac, web, DB, off-site) | [connect-to-databases.md](recipes/connect-to-databases.md#overview) |

Diagrams are [Mermaid](https://mermaid.js.org); GitHub renders them inline; `make mermaid` renders them all.

## Command reference

| Tool | Runs on | Main commands / flags |
|---|---|---|
| [`bin/siwo`](../bin/siwo) | workstation | `list`, `<area> <tool>`, `do`, `cf`, `ploi`, `gcp`, `keys`, `health`, `credentials`, `env`, `addon`, `monitor`, `status`, `configure`, `profile`, `plans`, `py`; `--dry-run --yes --force --json --verbose --quiet`, see [cli.md](tools/cli.md) |
| [`docker-db-server-manager.sh`](../src/shell/db/docker-db-server-manager.sh) | DB server (root) | `init install upgrade reset status verify doctor [--alert] env create-db create-user grant rotate-password list-dbs list-users drop-db drop-user role-split env-init env-apply env-list env-sql env-creds purge-trash backup restore restore-test offsite pitr binlog-ship binlog-replay engine gfs-keep cron-install cron-remove logs monitor-user metrics tls-ca pg-major-upgrade migrate-managed uninstall help`; `--yes --dry-run --non-interactive --snapshot --snapshot-taken --no-snapshot --config --quiet --version`, see [db-server-manager.md](tools/db-server-manager.md) |
| [`remote-run.sh`](tools/remote-run.md) | workstation | `--host -i --expect-ip --env-file --config --no-config --sudo --script --no-upload --snapshot-with --dry-run -- <cmd>, <cmd>` (defaults from the root `.env`) |
| [`update-env-db.sh`](../src/shell/web/update-env-db.sh) | web server or workstation | `--env --site --from --set --remote --no-backup --dry-run` |
| [`check-db-reach.sh`](../src/shell/web/check-db-reach.sh) | web server or workstation | `<db-ip> [ports]`, `--env FILE`, `--remote ALIAS`, `--db-region R` |
| [`diagnose.sh`](../src/shell/web/diagnose.sh) | workstation or web server | `--host --site --path --env --owner --fix --yes --dry-run --json-summary`, see [server.md](tools/server.md) |
| [`server/init.sh`, `harden.sh`, `update.sh`, `inventory.sh`, `status.sh`](../src/shell/server) | workstation (`--host`) or the server | plan first, `--yes` to apply; see [server.md](tools/server.md) |
| [`env.sh`](../src/shell/env/env.sh) | workstation (`--host`) or web server | `init`, `check`; `--env --site --path --from --set --addons --dry-run --yes`, see [env.md](tools/env.md) |
| [`addon.sh`](../src/shell/addons/addon.sh) | the add-on's node (root) | `list plan install status doctor laravel-env remove garage-node-id`, see [addons.md](tools/addons.md) |
| [`monitor.sh`](../src/shell/monitor/monitor.sh) | each monitored node (root) | `list plan install targets beszel-register beszel-key tunnel caddy status doctor remove`, see [monitor.md](tools/monitor.md) |
| [`wireguard.sh`](../src/shell/net/wireguard.sh) | workstation | `setup status remove`, see [net.md](tools/net.md) |
| [`fixkeys.sh`](../src/shell/ssh/fixkeys.sh) | the server's console (root) | `--user --key-file --file --root --yes`, see [recover-ssh-lockout](recipes/recover-ssh-lockout.md) |
| [`db-tunnel.sh`](../src/shell/tunnels/db-tunnel.sh) | workstation | `<postgres\|pgbouncer\|mysql\|mariadb\|adminer\|all> --host --private-ip --background --print` |
| [`ploi-deploy.sh`](../src/shell/deploy/ploi-deploy.sh) | pasted into Ploi | SETTINGS block, see [deploy-script.md](tools/deploy-script.md#settings) |
| [`stacks/caddy`](../stacks/caddy) | Docker web server | `docker compose up -d`, `caddy reload`, see [caddy-stack.md](tools/caddy-stack.md#day-2-reload-logs-upgrades) |
