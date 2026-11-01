# Profiles reference

Profiles are versioned `KEY=VALUE` files in [`config/profiles/`](../../config/profiles). Each one is layered
onto [`_defaults.conf`](../../config/profiles/_defaults.conf): profile keys win, then `--set KEY=VALUE`.
No profile holds secrets. How to use them: [the configure guide](../configure.md).

```bash
bin/siwo profile list                         # name, version, description
bin/siwo profile show production-single       # resolved values; * = set by the profile
bin/siwo profile show dev-budget --check --set APP=shop --set CLIENT=acme   # plus the checks
bin/siwo profile diff dev-budget production-single
bin/siwo profile table                        # regenerates the table below
```

## Profiles

| Profile | For | DB droplet | Notes |
|---|---|---|---|
| `dev-budget` | development and staging on a budget | 2 GB | Postgres + PgBouncer only; tst/dev/stg share the droplet; nightly backups copied off-site; DO Spaces for files |
| `staging` | one staging env that mirrors production | 2 GB | alerts on; monthly backups kept 3 months |
| `production-single` | production on one DB droplet | 4 GB minimum | PITR (pgBackRest), off-site, TLS, migrator role, alerts and uptime checks; `STRICT=1` |
| `production-ha` | no single point of failure in the app tier | managed | load balancer + 2 web nodes, DO Managed DB (or a replica, by hand), Spaces; mostly documented steps |
| `mysql-app` | a Laravel app on MySQL | 2 GB | no Postgres or PgBouncer |
| `multi-engine` | Postgres, MySQL and MariaDB side by side | 4 GB | ~3.4 GB for the engines (estimate) |
| `cross-region-wireguard` | web and DB in different regions | 2 GB | WireGuard tunnel inside `VPC_CIDR`; extra latency per query (estimate: a few ms to tens of ms) |

## What each profile changes

`·` = same as `_defaults`; **bold** = set by the profile; `derived` = filled in by configure
(`OFFSITE_ENDPOINT` becomes `https://<REGION>.digitaloceanspaces.com` when `OFFSITE=s3`).

| Setting | `_defaults` | `dev-budget` | `staging` | `production-single` | `production-ha` | `mysql-app` | `multi-engine` | `cross-region-wireguard` |
|---|---|---|---|---|---|---|---|---|
| `PEER_REGION` | (empty) | · | · | · | · | · | · | **ams3** |
| `DB_MODE` | self | · | · | · | **managed** | · | · | · |
| `DB_DROPLET_MB` | 2048 | · | · | **4096** | **4096** | · | **4096** | · |
| `WEB_DROPLET_MB` | 2048 | · | · | **4096** | **4096** | · | · | · |
| `WEB_NODES` | 1 | · | · | · | **2** | · | · | · |
| `LOAD_BALANCER` | 0 | · | · | · | **1** | · | · | · |
| `WIREGUARD` | 0 | · | · | · | · | · | · | **1** |
| `MIN_DB_MB` | 1024 | · | · | **4096** | **4096** | · | · | · |
| `STRICT` | 0 | · | · | **1** | **1** | · | · | · |
| `DO_ALERTS` | 0 | · | **1** | **1** | **1** | · | · | · |
| `UPTIME_CHECKS` | 0 | · | · | **1** | **1** | · | · | · |
| `ENABLE_POSTGRES` | 1 | · | · | · | · | **0** | · | · |
| `ENABLE_PGBOUNCER` | 1 | · | · | · | · | **0** | · | · |
| `ENABLE_MYSQL` | 0 | · | · | · | · | **1** | **1** | · |
| `ENABLE_MARIADB` | 0 | · | · | · | · | · | **1** | · |
| `PG_APP_CREATEDB` | 1 | · | · | **0** | **0** | · | · | · |
| `TLS_MODE` | off | · | · | **require** | **require** | · | · | **require** |
| `ENVS` | (empty) | **tst dev stg** | **stg** | **prd** | **prd** | **dev stg** | **dev stg** | **dev stg** |
| `TENANT_ENVS` | (empty) | **tst dev stg** | **stg** | · | · | **dev stg** | **dev stg** | **dev stg** |
| `PROTECTED_ENVS` | stg prd | **stg** | **stg** | **prd** | **prd** | **stg** | **stg** | **stg** |
| `PRD_LOCATION` | local | **droplet** | **droplet** | · | **managed** | **droplet** | **droplet** | **droplet** |
| `ENV_MIGRATOR` | 0 | · | · | **1** | · | · | · | · |
| `RETENTION` | daily=7 weekly=4 | · | **daily=7 weekly=4 monthly=3** | **daily=14 weekly=8 monthly=12 yearly=2** | · | · | · | · |
| `PITR` | off | · | · | **pgbackrest** | · | · | · | · |
| `OFFSITE` | none | **s3** | **s3** | **s3** | · | **s3** | **s3** | **s3** |
| `OFFSITE_ENDPOINT` | (empty) | derived | derived | derived | · | derived | derived | derived |
| `STORAGE` | none | **spaces** | **spaces** | **spaces** | **spaces** | **spaces** | **spaces** | **spaces** |
| `MONITOR_STACKS` | none | · | **beszel** | **beszel,kuma** | **beszel,kuma** | · | · | · |
| `MONITOR_HUB` | web | · | · | · | **dedicated** | · | · | · |

## Settings

Where a setting ends up: **plan** = only `local/<client>/workbench.conf` (used by the checks and the next
commands), **db** = also `db-server.conf` (the manager's `/etc/docker-db-server-manager.conf`),
**addons** = also `addons-<role>.conf` (`/etc/vsw-addons.conf` on that node), **monitor** = also
`monitor-<role>.conf` (`/etc/vsw-monitor.conf` on that node).

| Setting | Goes to | Values | Meaning |
|---|---|---|---|
| `CLIENT` | plan | `a-z 0-9 -` | names the folder `local/<client>/` (set with `--client`) |
| `CLOUD` | plan | `do` `gcp` | which region list, machine sizes and off-site default the checks use |
| `REGION` | plan | DO slug (`nyc3`, `ams3`, ...) or GCP region (`us-central1`) | region of the servers; checked against the `CLOUD`'s list (a GCP zone is refused; an unknown but well-formed GCP region is an info) |
| `PEER_REGION` | plan | as `REGION` | the other region; DO needs `WIREGUARD=1` for it, a GCP VPC network spans regions |
| `VPC_CIDR` | db | private IPv4 CIDR | what the DB accepts connections from (ufw and `pg_hba`) |
| `DB_PRIVATE_IP` | db | IPv4 in `VPC_CIDR` | written as `PRIVATE_IP` and `EXPECTED_PRIVATE_IP`; empty = the manager detects `eth1` |
| `WEB_PRIVATE_IP` | plan | IPv4 in `VPC_CIDR` | for the checks only |
| `DB_MODE` | plan | `self` `managed` `replica` | `managed`: no `db-server.conf`, no add-ons on a DB node |
| `DB_DROPLET_MB` `WEB_DROPLET_MB` `DEDICATED_DROPLET_MB` | plan | MB | droplet RAM, checked against what runs there |
| `SINGLE_DROPLET` | plan | 0/1 | web and DB on one droplet (dev only): one `db+web` node of `DB_DROPLET_MB`, every estimate added up; also assumed when `DB_PRIVATE_IP` = `WEB_PRIVATE_IP` |
| `WEB_NODES` | plan | 1+ | more than 1 needs `LOAD_BALANCER=1` and shared storage |
| `LOAD_BALANCER` | plan | 0/1 | a DO load balancer in front of the web nodes |
| `WIREGUARD` `WIREGUARD_CIDR` | plan | 0/1, CIDR | cross-region tunnel; `WIREGUARD_CIDR` must lie inside `VPC_CIDR` |
| `MIN_DB_MB` | plan | MB | the profile's floor for `DB_DROPLET_MB` |
| `STRICT` | plan | 0/1 | best-practice warnings become errors |
| `HARDEN` | plan | 0/1 | run `bin/siwo server harden` after setup |
| `DO_ALERTS` `UPTIME_CHECKS` | plan | 0/1 | DO monitoring alert policies and uptime checks |
| `APP` `PG_USER` `PG_DB` | db | `a-z 0-9 _` | app name (databases `<app>_<env>`), default role and database |
| `ENABLE_POSTGRES` `ENABLE_PGBOUNCER` `ENABLE_MYSQL` `ENABLE_MARIADB` `ENABLE_ADMINER` | db | 0/1 | engines (PgBouncer needs Postgres) |
| `PG_APP_CREATEDB` | db | 0/1 | the app role may create (tenant) databases |
| `TLS_MODE` | db | `off` `require` `verify-full` | TLS between web and DB; `verify-full` also checks the CA and host (`tls-ca`) |
| `ENVS` `TENANT_ENVS` `PROTECTED_ENVS` | db | `tst dev trn stg prd` | environments, which have tenants, which need typed confirmations |
| `PRD_LOCATION` | db | `local` `droplet` `managed` | where prd lives |
| `ENV_MIGRATOR` | db | 0/1 | separate migrator role for DDL |
| `RETENTION` | db | `daily=N weekly=N monthly=N yearly=N` | backup rotation |
| `PITR` | db | `off` `pgbackrest` | point-in-time recovery (Postgres only) |
| `OFFSITE` `OFFSITE_ENDPOINT` `OFFSITE_REGION` `OFFSITE_BUCKET` | db | | off-site backup copies (S3 API, e.g. DO Spaces) |
| `ALERT_EMAIL` | db | email | where failures are mailed |
| `GOTENBERG` `GOTENBERG_ROLE` | addons | 0/1; `web` `db` `dedicated` | the PDF service and its node |
| `STORAGE` `STORAGE_ROLE` | addons | `none` `spaces` `garage` `seaweedfs` `rustfs`; role | object storage; `spaces` is managed (nothing to install) |
| `STORAGE_BUCKET` `STORAGE_DATA_DIR` | addons | | bucket name; data folder (a DO volume) |
| `MONITOR_STACKS` | monitor | `none` or any of `beszel` `kuma` `netdata` `prometheus` | monitoring stacks ([monitor guide](../tools/monitor.md)) |
| `MONITOR_HUB` | monitor | `web` `db` `dedicated` | node with the UIs and storage; every other node runs the agents |
| `MONITOR_PROBE_URLS` | monitor | http(s) URLs | endpoints the hub probes (blackbox exporter, Uptime Kuma) |
| `MONITOR_ALLOW_TIGHT` | monitor | 0/1 | allow heavy stacks (netdata, prometheus) next to a DB on 2 GB or less |

## RAM estimates used by the checks

Planning estimates in MB, not measurements: OS 512; Postgres 1024; PgBouncer 64; MySQL 1024; MariaDB 768;
Adminer 64; pgBackRest 128; web app (nginx, PHP-FPM, queue worker, scheduler) 1024; Gotenberg 1024; Garage 256;
SeaweedFS 512; RustFS 512. Monitoring hub: Beszel 64, Uptime Kuma 192, Netdata 256, Prometheus + Grafana +
Alertmanager 600; agents: Beszel 32, Netdata 256, exporters 120 (the `MON_RAM_MB` values in `stacks/monitor`). The engine numbers match `doctor` in the DB manager. Over 100% of the droplet is an
error (with the size to use: a DO slug, or an E2 machine type with `CLOUD=gcp`), over 85% a warning. Web
and DB on one droplet (`SINGLE_DROPLET=1`) is checked as one node: the OS once, plus everything else on it.

## Adding or changing a profile

1. Copy the closest profile, keep the header comment, and set `PROFILE_VERSION=1` (bump it on every change).
2. Only use keys that exist in `_defaults.conf`; unknown keys are refused.
3. Run `bin/siwo profile show <name> --check --set CLIENT=x --set APP=demo --set ALERT_EMAIL=ops@example.com`.
4. Regenerate the table above with `bin/siwo profile table` and run `make ci`.
