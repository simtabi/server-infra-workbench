# Status: done vs open

## Done

| Area | What |
|---|---|
| DB server | Postgres + PostGIS + pgvector, PgBouncer (session, scram, `auth_query`), MySQL, MariaDB, each optional (`engine enable\|disable`); bound to the private IP only; idempotent `install`; `init`, `verify`, `doctor [--alert]`, `create-db`, user management, optional loopback-only Adminer, optional TLS |
| Least privilege (1.4.0) | one admin superuser; app logins without admin attributes; no `root@'%'`; [privileges](reference/privileges.md) |
| Environments (1.4.0) | `<app>_<env>` databases and roles, tenants by prefix, protected envs with `--force-prod`, fresh backup and soft drop; [guide](database-environments.md) |
| Backups | nightly cron, atomic (`.partial` then rename), free-space check, manifest + checksums, GFS `RETENTION`, encrypted off-site copies, pgBackRest PITR, binlog shipping, weekly `restore-test`, alerts; [backups](backups-and-recovery.md) |
| Upgrades | config file first, wrong-server guard, `remote-run.sh` from the workstation |
| Web | `update-env-db.sh` (idempotent, masked, `.bak` pruning), `check-db-reach.sh` |
| Deploy | generic Ploi script: `laravel`/`generic` presets, optional hooks, zero-downtime or in-place, first-install marker, `.env` symlink for Ploi's editor, `chmod 600` |
| Docker web | Caddy + php-fpm compose with automatic HTTPS |
| Guided upgrade | manager 1.3.0 `upgrade`: preflight, diff, snapshot offer, verified backup, savepoint, apply, verify, auto-rollback, lock, redacted log |
| Platform APIs (P3) | PHP 8.4 REST clients on one HTTPS-only transport (retries with `Retry-After`, quota waits, pagination, timeouts, redacted logs, typed errors): DigitalOcean (droplets, resize, snapshots, volumes, VPCs incl. default, firewalls, monitoring and uptime, SSH and Spaces keys, domains/DNS, reserved IPs, projects, tags), Cloudflare (zones, DNS, SSL mode and zone settings, Origin CA, cache purge, IP access rules, WAF read), GCP (instances, snapshots, firewalls, Cloud DNS, Cloud Storage; service-account JWT), GitHub (repos, Actions runs/dispatch, libsodium-sealed secrets, deploy keys, releases), Ploi (servers, sites, deploy, daemons, cron, databases, certificates); pending actions, dry runs, audit log, one-time secrets to a 600 file; mocked unit and contract tests, gated live read-only tests; [providers](providers/README.md) |
| CLI | `bin/workbench`: shell tools, `do`/`cf`/`ploi`/`gcp`/`github` (incl. `do resize`, alerts, firewalls; `do droplet-create` defaults to the newest Ubuntu LTS, `ubuntu-26-04-x64`, [why](tools/cli.md#default-droplet-image)), `keys`, `configure` + profiles, `credentials`, `py` |
| Server tools | `server init`, `harden`, `update --reboot-window`, `inventory`, `web diagnose [--fix]`, `env init\|check`, `fixkeys.sh` console recovery; [server tools](tools/server.md) |
| Cross-region | `EXTRA_BIND_IPS`, `PEER_REGIONS`, `VPC_PEERING`, public bind only with `ALLOW_PUBLIC_BIND=1` + TLS; `doctor` and `check-db-reach` region/VPC checks; `net wireguard setup\|status\|remove`; [cross-region](cross-region.md) |
| Monitoring (P2) | `bin/workbench monitor`: Beszel, Uptime Kuma, Netdata, Prometheus + Grafana + exporters, per role, loopback UIs, private agents, RAM gate; backup/restore-test textfile metrics and alert rules; `bin/workbench status`; [monitor](tools/monitor.md), [ADR 0012](adr/0012-monitoring-stack.md) |
| Manager 1.5.0 | `TLS_MODE=verify-full` + `tls-ca`, `monitor-user`, `metrics`, `migrate-managed`, `pg-major-upgrade` (auto-rollback, `--cleanup`); [recipes](recipes/pg-major-upgrade.md) |
| Progress UX | one contract for shell, PHP and Python: steps, bars, spinners; plain lines off a TTY, `NO_COLOR`, `--quiet` |
| Docs | [lessons learned](lessons-learned.md), [checklists](checklists/README.md) per phase (command, verify, why), [privileges](reference/privileges.md) with the reason per row, ADRs 0001-0013, the [live rollout runbook](runbooks/live-rollout.md) |
| Add-ons | Gotenberg; Garage, SeaweedFS, RustFS (experimental) object stores; [add-ons](tools/addons.md) |
| Examples | every catalog entry is a runnable example (`examples/run.sh --all`, offline): Laravel (multitenant, Horizon + Reverb, Octane, MySQL, Gotenberg), WordPress, Symfony, Next.js, NestJS, Django, FastAPI, Rails, Go, static Caddy, plain Ploi site, all-in-one dev droplet, split and cross-region layouts, two web nodes behind a load balancer, managed Postgres, GCP VM, PITR to Spaces, Cloudflare DNS, storage, monitoring; shared pieces in `examples/_shared` with self-tests; [catalog](../examples/README.md). Offline only: none was deployed live |
| Quality | pinned shellcheck, smoke tests, runnable examples, deploy sandbox, nine Docker integration suites in `make it` (upgrade, add-ons, server tools, DB features, PITR posix and S3, Garage cluster, monitoring, WireGuard) with a leak guard, secrets check (scanner + gitleaks), link, table and documented-command checks, generated config-keys and config-examples checks, compose validation, client-data check, Pint, PHPStan max, PHPUnit (mock HTTP server), Python unittest, CI and `make ci-local` ([tests](../tests/README.md)) |

## Open / Roadmap (ranked)

Ranked by risk to data first, then by how likely the gap is to bite.

| # | Gap | Why it matters | Suggested approach |
|---|---|---|---|
| 1 | <a id="restore-test"></a>**~~Restore test~~ (done in 1.4.0)** | Fixed: `restore-test` loads the newest backup into throwaway containers with no network and compares the manifest; weekly from `cron-install`; `doctor` warns after `RESTORE_TEST_MAX_AGE_D` days. | Still do the [monthly drill](checklists/monthly-restore-drill.md) from off-site copies on a scratch droplet. |
| 2 | <a id="point-in-time-recovery"></a>**~~Point-in-time recovery~~ (done in 1.4.0, container-tested in P2)** | `PITR=pgbackrest` archives WAL to S3/Spaces or a posix repo; `binlog-ship` copies MySQL/MariaDB binlogs. `pitr-it` restores a posix repo to a timestamp end to end (prd guard, pre-restore dump, verify, new full backup); `pitr-s3-it` (P3) does the same through an S3 repo (Garage behind TLS, path style, private CA, encrypted). Binlog replay is not container-tested. | Rehearse `pitr restore` against the real Spaces repo on a scratch server (host style, public CA: not reproducible locally) ([backups](backups-and-recovery.md#restore)). |
| 3 | <a id="monitoring"></a>**~~Monitoring and alerts~~ (done in P2)** | `bin/workbench monitor` adds metrics, dashboards and alert rules on top of `doctor --alert` and the DO alerts ([monitor](tools/monitor.md)). | Still point `HEALTHCHECK_URL` at a check-in monitor so a dead cron is noticed too. |
| 4 | <a id="postgres-major-upgrade"></a>**~~Major Postgres upgrade~~ (done in 1.5.0)** | `pg-major-upgrade --to N`: verified backup, dump/reload, inventory compare, auto-rollback; the old data is kept until `--cleanup` ([recipe](recipes/pg-major-upgrade.md)). Container-tested 18 to 19 (release candidate). | Wait for PostGIS/pgvector packages for the new major; minor versions only need `install`. |
| 5 | <a id="create-db-pgbouncer"></a>**~~`create-db` users vs PgBouncer~~ (done in 1.2.0)** | Fixed: PgBouncer uses `auth_user=PG_USER` + `auth_query`, so every Postgres login role pools through 6432. | Apply on an existing server with `install` ([rollout plan](recipes/roll-out-a-manager-upgrade.md)). |
| 6 | <a id="private-network-encryption"></a>**~~Encryption on the private network~~ (done in 1.5.0)** | `TLS_MODE=verify-full`: a CA on the DB server, PgBouncer verifies Postgres, clients pin the CA ([recipe](recipes/verify-full-tls.md)). WireGuard between droplets is done (`net wireguard`). | Roll it out per server: `upgrade`, copy `tls-ca` to the web hosts, `DB_SSLMODE=verify-full`. |
| 7 | <a id="platform-coverage"></a>**Platform API coverage** | P3 covers DigitalOcean, Cloudflare, GCP, GitHub and Ploi end to end for the runbooks ([providers](providers/README.md)). Not covered: DO VPC peering and managed databases, Cloudflare WAF rule writes (read-only on purpose), GCP IAM. Live tests are read-only; writes are tested with mocks and `--dry-run` only. | Add endpoints as the runbooks need them, each with a mocked test, a CLI command and a docs row ([platform-api.md](tools/platform-api.md#adding-a-platform)). Next: `do vpc-peering`, `do db trusted-sources`.  <!-- vsw-commands: ignore (proposed, not built) --> |
| 8 | <a id="ha"></a>**High availability** | One DB server and one web node are single points of failure. | [High availability](high-availability.md): managed prd with a standby ([ADR 0008](adr/0008-database-topology.md)), two web nodes behind a load balancer. |
| 9 | <a id="not-tested"></a>**Not covered by integration tests** | Swap, Docker install and `--host` for server tools are tested offline only. | Add container tests as these get used. Covered since P2: PITR restore (posix, `pitr-it`), MySQL 9.7 (`db-features-it`, the default `MYSQL_IMAGE`), the 18 to 19 major upgrade, `verify-full`, `migrate-managed`, the monitoring stacks (`monitor-it`), a real two-host WireGuard tunnel (`wg-it`, P3), PITR with an S3 repo (`pitr-s3-it`, P3), Garage in host networking as a three-node cluster (`garage-cluster-it`, P3), the RustFS install with its bucket-scoped app key (`addons-it`, P3). `addons-it` and `garage-cluster-it` run in parallel with another `make it` under `VSW_IT_PREFIX`; the other suites are not prefix-aware yet. Not container-tested: Garage bridge mode as a cluster (bridge is single-node by design; multi-node needs host networking and VPC IPs) and a multi-host Garage cluster over a real VPC. |

## Recommendations

What to do with the tools as they are, and what is only proposed. "Implemented" means a command exists, has
tests and is documented; "proposed" means nothing in the repo does it yet.

### Implemented: use these now

| # | Recommendation | Command | Why |
|---|---|---|---|
| 1 | Generate each setup from a profile into `local/<client>/` | `bin/workbench configure --profile dev-budget --client <client>` | sizes, regions, engines and backups are checked before anything runs |
| 2 | In dev, run only the engines the app uses | `M engine disable mysql`, `M engine disable mariadb` | frees RAM on a 2 GB droplet instead of paying for a resize; data volume kept |
| 3 | Upgrade existing servers to 1.5.0 with a dry run first | `remote-run.sh ... -- upgrade --dry-run`, then `-- upgrade` | removes the superuser app login and `root@'%'`, adds manifests and checks |
| 4 | Copy backups off the droplet | `M offsite backup`, `M offsite verify` | a backup on the same droplet is lost with it |
| 5 | Turn on alerts | `bin/workbench do alerts standard`, `do uptime check-create`, `HEALTHCHECK_URL` | nobody watches a dev server; alerts do |
| 6 | Diagnose before changing anything on a broken site | `bin/workbench web diagnose --site <domain> --env <env>` | most 503s were config: `.env`, migrations, IP or port |
| 7 | Keep web and DB in one region and VPC | `doctor` and `check-db-reach` warn otherwise | private traffic doesn't cross regions; peering or tunnels add cost and moving parts |
| 8 | Use the phase checklists | [checklists](checklists/README.md) | each step has a verify, so mistakes show up at that step |

### Proposed: not built yet

| # | Proposal | Why | Effort |
|---|---|---|---|
| 1 | ~~Major Postgres upgrade command~~ | done in 1.5.0 (`pg-major-upgrade`) | - |
| 2 | ~~Client-verifiable TLS~~ | done in 1.5.0 (`TLS_MODE=verify-full`) | - |
| 3 | Move prd to a managed database with a standby before launch | removes the single point of failure and the self-managed backups for prd ([ADR 0008](adr/0008-database-topology.md)) | low effort, monthly cost |
| 4 | `do vpc-peering` and managed-DB trusted-sources commands | cross-region peering is a dashboard step today | low  <!-- vsw-commands: ignore (proposed, not built) --> |
| 5 | ~~Container test for a two-host WireGuard tunnel~~ (done in P3: `wg-it`; PITR restore done in P2, `pitr-it`) | covered: kernel WireGuard with `NET_ADMIN` only, real ssh and ufw | done |
| 6 | ~~Metrics and dashboards~~ | done in P2 (`bin/workbench monitor`) | - |
| 7 | A second web node behind a load balancer | one web node is a single point of failure | cost |
