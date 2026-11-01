# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (manager 1.6.0: database users, engine toggles, local clients)

- Master login per engine ([users and privileges](docs/databases/users-and-privileges.md),
  [ADR 0015](docs/adr/0015-master-users-and-engine-toggles.md)): MySQL/MariaDB get a named admin
  (`MYSQL_ADMIN_USER` / `MARIADB_ADMIN_USER`, default `siwo_admin`) limited to `MY_ADMIN_HOSTS` (default the
  Docker network and `VPC_CIDR`; `%` and `/0` refused) with `MY_ADMIN_PRIVS` and `MY_ADMIN_GRANT_OPTION`;
  `root` stays server-local. Passwords are generated into `/opt/db/.env` (600), re-synced on every converge and
  never printed. `admin-creds <engine> --out F` writes one master login to a new 600 file.
- `engines [status]` and `engines apply [--set ENABLE_<ENGINE>=0|1]... [--dry-run] [--purge]`: switch engines
  on or off on a running server touching only the changed services (backup first; the others keep their
  containers, checked); volumes kept unless `--purge` with a typed confirmation. `engine enable|disable` now
  runs through it. `bin/siwo db engines status|plan|apply` does the same from the `SIWO_DB_ENABLE_*` toggles in
  the workstation `.env` (no password is sent).
- Every manager key can be written `SIWO_DB_<KEY>` (environment or config file); the plain key wins.
- `DB_READONLY_USER=1` makes every `create-db` add `<name>_ro`; `MY_OWNER_PRIVS`, `MY_RW_PRIVS`, `MY_RO_PRIVS`
  are configurable (global and dangerous privileges refused).
- `.env-example` (tracked) for the workstation `.env`: engine toggles, master users, privilege settings, SSH
  tunnel host and local ports, placeholders only. `make env-check` (first step of `make ci`) and the
  `no-env-files` pre-commit hook fail when a `.env` or credentials file is tracked or staged.
- `db-tunnel.sh --env-file F` reads `SIWO_DB_SSH_HOST`, `SIWO_DB_PRIVATE_IP` and `SIWO_DB_LOCAL_*` from `.env`.
- Docs: [Connecting local DB clients](docs/databases/connecting-local-clients.md) (TablePlus, DBeaver,
  DataGrip/PhpStorm, psql/mysql over `ssh -L`), [Users and privileges](docs/databases/users-and-privileges.md).
- Tests: `tests/shell/db-users-it.sh` (`make it`): master users, idempotent `create-db`/`create-user`,
  grants, and MySQL + MariaDB switched off with Postgres answering queries throughout (same container),
  re-enable with data back, `--purge`.

### Changed (manager 1.6.0)

- `create-db` and `create-user` are idempotent: only what is missing is created; an existing login keeps its
  password and gets its grants re-applied (no credentials file is written for it). An owner that is a
  superuser or a master login, or an existing database whose schema `public` belongs to another login, is
  refused.
- `.gitignore` regrouped: env files (`.env`, `.env.*`, `*.local`; templates kept), credentials and `--out`
  files, keys, dumps and backups, the local client folder, logs, dependency and tool caches, Python venvs,
  OS/IDE files, live-test state.

### Changed (project renamed: server-infra-workbench)

- The project is now `server-infra-workbench` (was `vps-server-workbench`); it covers far more than one VPS
  ([ADR 0014](docs/adr/0014-rename-to-server-infra-workbench.md)). GitHub redirects the old URLs.
  - Composer package `simtabi/server-infra-workbench`, PHP namespace `Simtabi\ServerInfraWorkbench`, Python
    package `server_infra_workbench`.
  - The command is `siwo` (Server + Infrastructure + WOrkbench): `bin/siwo`, console script `siwo-py`,
    `src/php/bin/siwo-php`. `bin/workbench` is a deprecated shim that prints one notice and runs `bin/siwo`;
    `workbench-py` still works. Help text, docs, examples, runbooks and checklists use `siwo`, and
    `make docs-commands` fails on `bin/workbench` in the docs. `remote-run.sh --snapshot-with siwo`
    (`workbench` still accepted).
  - Environment variables are `SIWO_*` (the command's name). An unset `SIWO_X` falls back to `VSW_X` and prints
    one deprecation note.
  - Credentials, `keys.json` and the audit log live under `~/.config|~/.local/state/server-infra-workbench/`;
    an existing `vps-server-workbench` directory keeps being used while the new one does not exist. Server
    directories (`/etc`, `/var/lib`, `/var/log`, `/usr/local/lib`) follow the same rule (`siw_path`).
  - Temporary files use `siw-`; live tests tag `siw-livetest` with prefix `siwlt-`, and `tests/live/sweep.sh`
    still sweeps the old `vsw-livetest` / `vswlt-` names.
  - Short `vsw` names already on servers are kept (database roles, `vsw_*` metrics and dashboards,
    `/opt/vsw-*`, `/etc/vsw-*.conf`, the `vsw_db` network); see
    [naming](docs/reference/naming.md#frozen-identifiers). `# Managed by` headers get the new name on the
    next re-run.

### Fixed (pre-release audit, 2026-11-01)

- Deploy script on zero-downtime sites: `queue:restart`, `POST_DEPLOY_CMDS` and `HEALTHCHECK_CMD` ran before
  Ploi made the release live, so workers restarted on the old code and the health check tested the old
  release. The main script now builds the caches in the release and stops; the same script with
  `STAGE="post"` in Ploi's post-deploy script runs the live steps (`examples/_shared/ploi-script.sh --post`).
  In-place sites are unchanged.
- `configure` checked web and DB on one droplet as two machines (the OS counted twice, each role against its
  own size). `SINGLE_DROPLET=1` (or equal `DB_PRIVATE_IP`/`WEB_PRIVATE_IP`) now checks one `db+web` node of
  `DB_DROPLET_MB`, with add-ons and monitoring placed on either role added in; stg/prd on it is flagged.

### Added (pre-release audit, 2026-11-01)

- `configure`: `CLOUD=gcp` checks GCP region names (a zone is refused with its region; an unknown well-formed
  region is an info), suggests E2 machine types, defaults the off-site endpoint to GCS, allows a second region
  without WireGuard (global VPC network) and refuses the DO-only `DO_ALERTS`/`UPTIME_CHECKS`.

### Added

- Platform APIs (P3 provider audit): full REST coverage for five providers on the shared transport, each with a
  guide in [docs/providers](docs/providers/README.md) (why, least-privilege token per command, command reference,
  checklist, lessons learned):
  - DigitalOcean: `do volumes` (grow only), `do vpcs` (default handling; refuses deleting the default or a VPC with
    members), `do spaces-keys`, `do domains`, `do dns`, `do reserved-ips`, `do projects`, `do tags`, `do ssh-keys`
    (alias of `keys account --provider digitalocean`), `do regions`/`sizes`, `do power`, `do droplet-delete`.
  - Cloudflare: `cf settings` and `cf ssl` (weakening needs `--force`), `cf origin-certs` (key and CSR made
    locally), `cf purge`, `cf firewall` (IP access rules; custom WAF rules read-only).
  - GCP: `gcp instance` create/start/stop/reset/delete, `gcp firewall-create`/`firewall-delete` (world-open
    non-web ports need `--force`), Cloud DNS (`gcp dns`, atomic changes), Cloud Storage (`gcp buckets`, private
    and versioned by default).
  - GitHub (new, `workbench github`, alias `gh`, `GITHUB_TOKEN`): repos, Actions runs/wait/dispatch/rerun/cancel,
    repository and environment secrets sealed locally with libsodium (value only from a file or stdin), deploy
    keys (read-only unless `--write --force`), releases.
  - Ploi: crons, databases (generated password to a 600 file), Let's Encrypt certificates, `server-restart`.
- One-time secrets (Spaces secret keys, Origin CA private keys, generated database passwords) are returned as an
  `IssuedCredential`, never serialised, and written by the CLI to `--out` (mode 600, created exclusively, refused
  inside the git checkout, checked before any request).
- Transport: GitHub `Link` pagination, rate-limit awareness (quota headers; GitHub's 403 with
  `x-ratelimit-remaining: 0` waits for the reset like a 429).
- Tests: mocked unit and contract tests for every new resource and the CLI, and a gated live read-only suite
  (`VSW_LIVE=1`, `phpunit --testsuite live`) whose client refuses anything but GET.
- DB manager: `log-errors [--since 24h|7d|all] [--service postgres|pgbouncer]`, a read-only, grouped and masked
  summary of Postgres/PgBouncer ERROR/FATAL lines (exit 1 when there are any); `doctor` warns on Postgres log
  errors in the last 24 h ([plan](docs/plan/postgres-log-quoting-errors.md)).
- `bin/workbench db pg-log-errors --host <db-alias>`: the same summary from the workstation over ssh, nothing
  installed on the server.
- Examples: the 17 catalog entries still marked planned are now runnable examples, each mapped to a profile
  and validated offline by `examples/run.sh`: laravel-horizon-reverb, laravel-octane, wordpress, symfony,
  node-nextjs, nestjs, django, fastapi, rails, go-api, static-site-caddy, ploi-managed-site,
  single-droplet-all-in-one, ha-two-web-lb, gcp-vm, backups-pitr-spaces, cloudflare-dns-proxy. Each has a
  README with the reasons, `.env.example`-style settings (secrets generated on the server, never in the repo)
  and its Ploi deploy settings, daemons and Nginx snippets where it needs them.
- `examples/_shared`: `app-env.sh` (the DB block in each stack's own names, the password in a pgpass file, not
  a URL; `--stack none` for app keys only), `with-env.sh`, `reload-daemon.sh` (restart by port after Ploi
  activates the release, wait for health), `nginx-proxy.conf`, `ploi-script.sh` (the generic deploy script with
  an example's settings; `--check`). `run.sh` runs `selftest` lines and checks every `ploi-deploy.settings.sh`.
- DB manager: `binlog-replay --target 'YYYY-MM-DD HH:MM:SS' [--engine] [--from DIR] [--force-prod] | --prepare`,
  MySQL/MariaDB point-in-time restore: newest dump finished before T, then the shipped binlogs from the dump's
  position up to T (UTC). Guards like `restore` (type RESTORE; protected envs need `--force-prod`), ships the
  binlogs and takes a safety backup first, refuses a binlog gap, skips account statements, takes a new backup
  after. `backup` records each MySQL/MariaDB dump's binlog coordinates and UTC finish time. MySQL images lack
  `mysqlbinlog`: a decoder image is built from `MYSQL_IMAGE` plus Oracle's signed client RPM of the same version
  (`MYSQLBINLOG_IMAGE` overrides).
- Tests: `mysql-pitr-it` (MySQL 9.7 and MariaDB binlog replay, in `make it`). Opt-in live tests on throwaway
  DigitalOcean resources, never in CI ([live tests](docs/live-tests.md)): `pitr-spaces-live` (PITR on a real
  Spaces bucket with a bucket-scoped key), `server-live` (swap, Docker and `--host` on a droplet, across a
  reboot), `garage-live` (3-node Garage over a real VPC, one node down). Shared `tests/live/lib`: dry run by
  default, cost guard, watchdog, trap teardown, verified cleanup; `make live-test`, `make live-sweep`.

### Changed

- The CLI is split into one command class per provider (`Console\Commands\*`) with a shared `Runner`; output,
  flags and exit codes are unchanged. `docs/tools/platform-api.md`, `cli.md`, `status.md` and
  `config/credentials.env.example` document the new scopes; the documented-command checker covers `github`/`gh`
  and two-word subcommands. CI installs `ext-sodium`.

### Fixed (test gaps, 2026-11)

- MySQL dumps did not load back into the same server (ERROR 3546, GTID_PURGED overlap; GTIDs are on in MySQL
  9.7): `backup` and the soft-drop dump use `--set-gtid-purged=OFF`. This affected `restore` of MySQL dumps.
- A MySQL- or MariaDB-only config (`ENABLE_POSTGRES=0`) was refused when the default `PG_EXTENSIONS` had postgis
  and the base image could not provide it: the check now runs only with Postgres on.

### Fixed (final audit, 2026-11)
- Python style gate never ran: ruff was optional and absent locally and in CI, and the code had drifted (89 findings, 8 files unformatted). Now formatted and clean under ruff 0.17.3, E501 left to the formatter, and CI installs ruff so `make py-lint` enforces it. Real fixes among the findings: `ApiClient` refuses any non-HTTPS URL (including API pagination links) before it builds a request with the bearer token, and errors chain their cause (`raise ... from`).
- Tests that read a file mode tried BSD `stat -f %Lp` first. GNU `stat -f` means filesystem status and exits 0, so on Linux (CI) the mode check compared garbage. They now try `stat -c %a` first, like the tools.
- MySQL healthcheck pinged the socket, which the image's temporary init server (`--skip-networking`) answers: the container went healthy, then restarted under the first hardening query (`ERROR 2002`, an intermittent install failure seen in db-features-it). It now pings over TCP (127.0.0.1), which only the final server answers; MariaDB already used `healthcheck.sh --connect`.
- server-it accepts `permitrootlogin prohibit-password` from `sshd -T`: OpenSSH 10 on Ubuntu 26.04 prints the canonical name, OpenSSH 9 printed the old alias `without-password`.
- Confirm prompts and `init` wrote to `/dev/stderr` / `/dev/stdout` by path. On Linux that reopens the file, so a run redirected to a log (`> log 2>&1`, `>> log`) lost everything printed before the prompt. They now write to fd 2 / fd 1, and a smoke check refuses the pattern (caught by CI on Linux; macOS dup()s these paths so local runs passed).

The rehearsal's "noted, not fixed" items and audit gaps:

- `backup()` names copies under `/etc/apt/*.d` `<file>.<ts>.bak` (apt warned "invalid filename extension" on
  every run for `.bak.<ts>`); `harden` renames older `20auto-upgrades.bak.<ts>` copies.
- `workbench do snapshots <droplet-id>` fills the DROPLET column (the per-droplet endpoint has no `resource_id`).
- DB manager: the generated Dockerfile gives `ARG PG_BASE_IMAGE` a default (no `InvalidDefaultArgInFrom`) and
  sets `DEBIAN_FRONTEND=noninteractive` as a build `ARG` (no debconf tty noise). Existing servers see this as a
  one-line Dockerfile diff on the next `upgrade`.
- `harden` without `--firewall` notes an inactive ufw and points at the DO cloud firewall or `--firewall --allow`.
- Garage `doctor`: 2 of 3 healthy nodes is a warning (quorum kept), a failure only below the write quorum.
- `server-it` and the `wg-it` image run on Ubuntu 26.04, the droplet default (`SERVER_IT_IMAGE=ubuntu:24.04`
  for the previous LTS).
- Examples: runnable `mysql-app`, `multi-engine-migration` and `managed-postgres-prd`, so every profile has a
  runnable example.

### Fixed (live rollout rehearsal, 2026-11)

A rehearsal of the [live rollout runbook](docs/runbooks/live-rollout.md) on throwaway droplets (a DB snapshot
clone, a web droplet, a three-node Garage cluster) found these ([report](docs/rehearsals/2026-11-live-rollout.md)):

- DB manager: `rebind-ip [--dry-run]` for a snapshot restored to a new private IP; `upgrade` preflight names it.
- DB manager: `upgrade --allow-unhealthy` for scripted runs on an unhealthy stack (dry runs continue to the plan).
- DB manager: a legacy stack on `db_default` is moved to `DOCKER_NETWORK` during the apply (was: "active endpoints", rollback).
- DB manager: old Postgres image tags are retired from a stack without `stack.env` (container tag) and on a no-op `upgrade`.
- DB manager: `PITR_S3_HOST_IP` (`extra_hosts` for a private S3 name); `offsite` trusts `PITR_S3_CA_FILE`
  (`RCLONE_CA_CERT` or `AWS_CA_BUNDLE`, one per tool); rclone runs without a config file notice.
- DB manager: `pitr setup` no longer takes a docker error for a pgBackRest version; the upgrade that turns PITR on
  treats the missing stanza as a warning instead of rolling back.
- DB manager: `doctor` reads unattended upgrades from `APT::Periodic` (the service unit is often disabled) and a
  failed doctor no longer prints an `ERROR: line N` trap line.
- `remote-run.sh` uploads to staging names, so a `root` login works ("are the same file").
- `net wireguard setup` refuses a tunnel /24 that overlaps a host network (exit 2).
- `monitor.sh plan` says when Docker is missing; `confirm()` without a terminal prints no `/dev/tty` error.
- Runbook: rclone install, PITR needs an upgrade first, `--yes` for scripted deletes, Docker for the monitoring hub,
  `addon.sh laravel-env` before task 15, `rebind-ip` after a restore to a new IP.

### Changed (droplet image)

- `workbench do droplet-create` defaults to the newest Ubuntu LTS, `ubuntu-26-04-x64` (was `ubuntu-24-04-x64`).
  One source of truth, `Droplets::DEFAULT_IMAGE`; override with `--image`, or per workstation with
  `VSW_DROPLET_IMAGE` (environment or credentials file). `--image latest` resolves the newest Ubuntu LTS from
  `GET /v2/images`, falling back to the constant. A unit test keeps the help and docs in step with the constant
  ([why](docs/tools/cli.md#default-droplet-image)).

### Added (P3: tests, examples, secret hygiene)

- `tests/shell/wg-it.sh` in `make it`: a real WireGuard tunnel between two containers (ssh, kernel WireGuard
  with `NET_ADMIN` only, ufw), skipped when the kernel lacks WireGuard ([networking](docs/tools/net.md)).
- [Examples catalog](examples/README.md) with profile and add-on mapping, and runnable examples
  (`examples/run.sh`, in `make test`): laravel-multitenant, split-web-db-vpc, cross-region-wireguard,
  monitoring, s3-storage, gotenberg.
- `make secrets-check` (in `make ci` and the pre-push hook): `tests/security/no-hardcoded-secrets.py` plus
  gitleaks with `.gitleaks.toml` over the full history ([security](docs/security.md#secrets-in-the-repository-generated-never-written-down)).
- PITR on S3-compatible storage: `PITR_S3_URI_STYLE` (host/path) and `PITR_S3_CA_FILE` (private CA, verified);
  a port in `OFFSITE_ENDPOINT` becomes `repo1-storage-port`; `validate` refuses an `http://` endpoint for an s3 repo.
  `tests/shell/pitr-s3-it.sh` in `make it` restores to a time through Garage behind TLS ([backups](docs/backups-and-recovery.md#pitr-repository-on-s3)).
- Garage clusters: `GARAGE_REPLICATION` (fixed at the first install; >1 needs host networking), `GARAGE_PEERS`
  joins, `addon.sh garage-node-id`; each install stages its role and the one that completes the cluster applies
  the layout and creates the bucket and key. `doctor` checks this node's role and the healthy node count.
  `tests/shell/garage-cluster-it.sh` in `make it` (host networking, three nodes, one node down); `addons-it` now
  installs RustFS ([garage](stacks/addons/garage/README.md#three-node-cluster)).
- `tests/docs/check-tables.py` in `make docs-commands`: every Markdown table row has its header's cell count.

### Changed (P3)

- `docs/lessons-learned.md`: six 3-column rows that sat in the 2-column Process table (their rule column was dropped by
  GitHub) moved to a new Testing and CI table.
- Every test password, token and key is generated per run (shell `openssl rand`, PHP `random_bytes`).
- The pgbouncer exporter gets a libpq `key=value` connection string built by `monitor.sh` into
  `secrets.env`; no URL with a password slot remains in a tracked file.
- `make compose-check` generates its dummy secrets and no longer sets the unused `PG_EXPORTER_DSN` keys.
- `make it` cleanup: `tests/shell/it-lib.sh` (`it_purge`, `it_rm_net`) removes each suite's containers, networks
  and volumes by compose project, detaching foreign containers first; every suite has its own subnet; the
  runner fails a suite that leaves `vsw*` containers, networks or volumes behind (and removes them).
- The manager's `up -d --wait` failures print each unhealthy container's state, exit code, OOM flag, last
  health probes and a redacted log tail, so a CI failure explains itself.

### Fixed (P3)

- `validate_config` refuses `postgis` in `PG_EXTENSIONS` on a base image that is not `postgis/*`. Before, the first
  boot's `CREATE EXTENSION postgis` failed mid-init, the container restarted on a half-initialised cluster with no
  extensions, and `install` passed only if the restart got healthy in time. This was the intermittent
  `monitor-it` "postgres unhealthy": that suite used `postgres:18` with the default extension list; it now sets
  `PG_EXTENSIONS`.
- `server-it` failed some runs at "sshd -T" while sshd showed exactly the expected settings: `sshd -T | grep -qx`
  under `pipefail` is false when grep exits on the first match and sshd gets SIGPIPE. The output is now captured,
  then grepped; the same for monitor-it's Prometheus rules and Grafana datasources bodies. The check also prints
  `sshd -t` / `sshd -T` and the drop-ins on failure (it was `2>/dev/null`, which hid the cause).
- RustFS: install now creates a bucket-scoped app key (IAM user + policy `vsw-app-<bucket>` through the admin
  API) and `laravel-env` writes it. Before, the app had no usable key unless you made one in the console, and
  a failed bucket create was only a warning. `doctor` checks the app key.
- `make it` runs can share one Docker daemon: `VSW_IT_PREFIX` / `VSW_IT_PORT_OFFSET` (it-lib) give
  `addons-it` and `garage-cluster-it` their own project names and ports, and the leak guard watches only its
  own prefix. Before, a second run recreated the first run's Garage containers and its leak guard could remove
  them. `addon.sh` takes `ADDON_PROJECT_PREFIX` and records `ADDON_PROJECT` in `stack.env`.
  It ignores an exported `COMPOSE_PROJECT_NAME` (the caddy stack documents one): honouring it would put every
  add-on in one compose project, and `uninstall` (`down --remove-orphans`) would remove the other add-ons.

- `reset` and `uninstall --purge` accept `--force-prod`. On a server with a protected env they told you to add
  the flag but never parsed it (only `RESET_FORCE_PROD=1` / `PURGE_FORCE_PROD=1` worked); unknown options are
  now refused instead of ignored.
- `make it` flake: the DB manager's `doctor` measured the laptop's disk (`DB_DIR` sits in `/tmp` in the suites).
  At 90% full it reported a PROBLEM, so `upgrade` rolled back and upgrade-it failed depending on how full the
  disk was. The limits are now keys (`DOCTOR_DISK_WARN_PCT`/`DOCTOR_DISK_BAD_PCT`, 80/90; add-ons
  `ADDON_DISK_WARN_PCT`/`ADDON_DISK_BAD_PCT`, 85/95), validated, and the suites set them to 100. Suites print
  the PROBLEM / `!!` lines on failure (`it_why`), not only a tail that had scrolled past them.
- `pitr-s3-it` flake: the TLS front joined the DB network after `install`, so the first boot's `archive_command`
  could wait on an unresolvable endpoint and the init server's shutdown ran past 60 s. The front now joins as
  soon as compose creates the network, as a reachable Spaces endpoint would be; the docs say the repo must answer first.

### Fixed (docs and command audit)

- `remote-run.sh --no-upload --config FILE` now uploads the config; before, the remote installed whatever
  `~/docker-db-server-manager.conf` an earlier run had left behind. Upgrade detection matches the command word
  (`upgrade`/`apply`), so `env-apply` and `pg-major-upgrade` no longer get `--snapshot-taken` (which
  `pg-major-upgrade` refused), and every upgrade segment in a `--` list gets the flag, not only the first.
- `bin/workbench do|cf|ploi|gcp`: a value option given twice (`--droplet A --droplet B`) is a usage error;
  it used to keep only the last one silently. Pass a comma-separated list.
- Live rollout runbook: task 11 passed `--droplet` twice (only the web droplet got alerts); `firewall-delete`
  and `alerts delete` rollbacks lacked `--force`.
- `--help` of 12 shell tools no longer prints bare `#` lines; the manager help lists `gfs-keep` and the global
  flags; `net wireguard` help lists `--ping`; `addon.sh` help lists `--force` and `--accept-experimental`.
- Config examples list the keys the code reads: `MONITOR_PG_USER/HOST/SSLMODE`, `MONITOR_PGBOUNCER_*`,
  `MONITOR_STACKS_DIR`, `CADDY_IMAGE` (monitor), `WAIT_TIMEOUT`, `ADDON_STACKS` (add-ons), `ALERT_ON_OK`,
  `DO_TOKEN_FILE` (manager). `web-db.env.example` no longer ships a placeholder password. The monitor example
  pointed at a non-existent `docs/decisions/` ADR path; `config/README.md` had the wrong add-ons conf path.
- `docs/README.md` command reference lists every tool and manager command; `bin/workbench list` shows
  `env`/`addon`/`monitor`/`status` as shell shortcuts (`env` was listed under Python) and `do resize|alerts`.
- Ubuntu 24.04 or 26.04 LTS in the docs; the `droplet-create` default image (`ubuntu-24-04-x64`) is documented.
- `examples/generic-laravel` gets the `example.conf` the catalog promised and says to copy into `local/`.

### Added (docs and command audit)

- `make docs-commands` checks DB manager commands (`M <cmd>`, the manager path, comma-separated `remote-run.sh --`
  lists) against its dispatch table and help, flags after `<placeholders>`, repeated PHP value options,
  destructive PHP commands without `--force`, and the reverse: every manager command, shell tool and PHP
  subcommand is documented somewhere.
- `tests/docs/check-config-examples.py` in `make links`: missing and dead keys in the config examples.
- [ADR 0013](docs/adr/0013-dev-on-2gb-postgres-only.md): dev and staging stay on 2 GB with Postgres only.
- Runbook optional tasks 16-19: dev budget, OS updates with a reboot window, `web diagnose`, the first
  off-site restore drill.

### Added (P2: manager 1.5.0, monitoring, progress)

- **Monitoring** ([monitor](docs/tools/monitor.md), [ADR 0012](docs/adr/0012-monitoring-stack.md)): `bin/workbench monitor`
  with any mix of `beszel`, `kuma`, `netdata` and `prometheus` (Prometheus, Alertmanager, Grafana with provisioned
  dashboards, node-exporter, cAdvisor, postgres/pgbouncer exporters, blackbox) per role (`hub`, `agent`, `both`).
  UIs on loopback (`tunnel`), agents on the private IP, pinned images, generated secrets in 600 files, RAM gate
  (exit 3), `doctor`, `targets`, `remove` (files kept). Profiles default to `beszel,kuma`; configurator keys `MONITOR_*`.
- `bin/workbench status`: one-screen, read-only health of one or more nodes, `--json`, health URLs.
- **Manager 1.5.0**: `TLS_MODE=verify-full` (CA on the server, PgBouncer verifies Postgres, `tls-ca`, `env` prints
  `DB_SSLROOTCERT`); `monitor-user` (`pg_monitor`, connection limit 5); `metrics` (node-exporter textfile, refreshed by
  backups, off-site copies and restore tests); `migrate-managed` (target credentials from a 600 file, extension and
  version checks, row counts compared); `pg-major-upgrade --to N` (verified backup, dump/reload, inventory compare,
  auto-rollback, `--cleanup`).
- `env init --addons` / `ENV_ADDONS=auto`: merges the add-ons' `laravel.env` files (600 only, values never printed).
- Progress UX for shell, PHP and Python (steps, bars, spinners; plain lines off a TTY, `NO_COLOR`, `--quiet`).
- `server harden` `dockergroup` item (`--fix-docker-group`), and a `doctor` warning for non-root docker group members.
- Recipes: [pg-major-upgrade](docs/recipes/pg-major-upgrade.md), [verify-full TLS](docs/recipes/verify-full-tls.md),
  [migrate-to-managed](docs/recipes/migrate-to-managed.md), [retag-postgres-image](docs/recipes/retag-postgres-image.md);
  [live rollout runbook](docs/runbooks/live-rollout.md); [P1/P2 plan](docs/plan/p1-p2-implementation.md).
- Tests: `smoke-monitor`, `smoke-progress`, `db-features-it` (verify-full, metrics, migrate-managed, 18 to 19 upgrade
  with rollback and cleanup), `monitor-it` (every stack in containers); `make it` runs the suites in order.

### Fixed (P2)

- Restore test waits for MySQL over TCP (the socket answered before the listener was up).
- `status.sh` no longer aborts when a stamp file is missing.
- Shell scripts no longer use `cmd | grep -q` (SIGPIPE + `pipefail` made a match look like a miss); this
  silently skipped Beszel's self-registration on `monitor install`.
- `monitor doctor` no longer exits mid-report when no target is down; Prometheus `file_sd` polls every 30s.
- Tests: `pitr-it` (PITR restore end to end on a posix repo) added to `make it`.

### Added (cross-region)

- `bin/workbench net wireguard setup|status|remove` ([networking](docs/tools/net.md)): plan and confirm, keys
  generated on each server and never printed (loaded by `PostUp`), ufw open to the peer only, Docker ordered
  after the tunnel on the DB side, Ploi-aware; 14 offline tests (`tests/shell/smoke-net.sh`).
- DB manager: `EXTRA_BIND_IPS` (tunnel or public address; public needs `ALLOW_PUBLIC_BIND=1` and
  `TLS_MODE=require`), `PEER_REGIONS`, `VPC_PEERING`; `PRIVATE_IP` must be a private address; the TLS
  certificate covers every bind address; `doctor` "Network: region and VPC" section (DO metadata).
- `check-db-reach`: `--db-region`, and warnings for a private IP outside this droplet's VPC or a public DB address.
- Docs: [Servers in different regions](docs/cross-region.md) (same region, VPC peering, WireGuard, public TLS
  with an allowlist, managed trusted sources) and [ADR 0011](docs/adr/0011-cross-region-connectivity.md).

### Added (manager 1.4.0: least privilege, environments, backups)

- **Least privilege** ([privileges](docs/reference/privileges.md), [ADR 0010](docs/adr/0010-least-privilege-database-roles.md)):
  `PG_ADMIN_USER` (`vsw_admin`) is the only Postgres superuser and owns every central database; the app login
  has no superuser/`CREATEROLE`/`REPLICATION`/`BYPASSRLS` and gets `CREATEDB` only for tenants
  (`PG_APP_CREATEDB`). `upgrade` performs the split (`role-split [--rollback]` by hand). PgBouncer uses a
  dedicated `pgbouncer_auth` login and a `SECURITY DEFINER` lookup that never returns superusers. MySQL/MariaDB:
  no `root@'%'`, `local_infile=0`, `secure_file_priv`, explicit per-database grant lists with `_` escaped.
  Optional `TLS_MODE=require` (self-signed, renewed by `upgrade`).
- **Environments** ([guide](docs/database-environments.md), [naming](docs/reference/naming.md)): `APP`, `ENVS`,
  `TENANT_ENVS`, `PROTECTED_ENVS`, `PRD_LOCATION`; `env-init` wizard or flags (`--dry-run`, exit 2 on a missing
  answer without a terminal), `env-apply`, `env-list`, `env-sql`, `env-creds [--out F]`. Per-env databases,
  `_owner`/`_app`/`_ro`/`_migrator` roles, `pg_hba` allow lists, secrets in `$ENV_SECRETS_DIR/<env>.env` (600).
- **Guard rails**: protected envs need `--force-prod`, the env name typed (or `WORKBENCH_CONFIRM`) and a verified
  backup younger than `FRESH_BACKUP_MIN`; drops are soft (Postgres rename to `__trash_<ts>`, MySQL dump kept
  `DROPPED_DUMP_DAYS`); `purge-trash`.
- **Backups** ([Backups and recovery](docs/backups-and-recovery.md)): manifest + `SHA256SUMS` per backup, GFS
  `RETENTION`, encrypted off-site copies (`offsite backup|list|verify|fetch`, openssl or age, rclone or aws),
  pgBackRest PITR (`pitr setup|backup|status|restore`, 2.60+), `binlog-ship`, weekly `restore-test` into
  throwaway containers with no network, `doctor --alert` with email/webhook/check-in/command alerts;
  `cron-install` writes all jobs.
- `engine enable|disable` with a RAM check and a `do resize` hint; `create-db --tenants --owner`;
  `doctor` checks roles, isolation, tenants, naming, MySQL hardening, TLS, backups, off-site, PITR and RAM.

### Fixed (manager 1.4.0)

- `restore-test` always removes its throwaway containers (a `RETURN` trap didn't fire from cron and left them
  running), and removes leftovers from older runs first.

### Added (configurator, platform commands)

- **`bin/workbench configure`** wizard and `profile list|show|diff|table` with 7 versioned profiles
  ([profiles](docs/reference/profiles.md)): RAM, region, VPC and best-practice checks; writes a client's config
  under the ignored `local/<client>/`.
- **`do resize`** (shutdown, resize, power on, as a pending action) and DO monitoring alert policies; DO
  firewalls, uptime checks, droplet create; Ploi sites, deploy scripts and daemons; health checks.
- **Add-ons** ([add-ons](docs/tools/addons.md), [ADR 0007](docs/adr/0007-object-storage-selection.md)): Gotenberg
  and one object store per node (Garage, SeaweedFS, RustFS experimental) via `addon.sh`, with plan, confirm,
  audit and container tests.
- **Client data out of the repo**: real setups live in ignored `local/`; `make client-check` denylist gate.

### Added (server tools)

- **`server harden`**, **`server update --reboot-window`**, **`web diagnose [--fix]`** ([server tools](docs/tools/server.md))
  on a shared library (plan, confirm, lock, audit, backups), all with `--dry-run` and `--host`.
- **`server init --role db|web|base`**: timezone, swap (+ `vm.swappiness=10` on db), base packages, Docker from
  Docker's apt repo with log rotation (db only, never under Ploi), then `harden`.
- **`server inventory`**: read-only facts as txt/json/md, `--out DIR` with dated copies and diffs, `--pull` into
  `local/<client>/inventory/<host>/`, `--install-cron` for a daily snapshot. Never reads `.env` values.
- `remote()` copies extra files and has a no-TTY mode for captured output.
- Tests: `tests/shell/smoke-server.sh` (59 tests, stubbed root) and `tests/shell/server-it.sh` (17 tests in an
  Ubuntu 24.04 container, part of `make it`).

### Added (Laravel .env)

- **`env.sh init|check`** ([Laravel .env](docs/tools/env.md)) with `config/laravel.env.example`: per-env defaults,
  `APP_KEY` generated only when empty, `DB_*` from `env-creds`, validation, key-only diff, backup, atomic 600
  write, typed confirmation on prd. `config/credentials.env.example` for platform tokens.

### Added (SSH keys: vps-ssh-key-manager merged)

- `workbench keys` for provider accounts (DigitalOcean, Vultr, Hetzner, Linode, Scaleway) and safe server
  `authorized_keys` editing, replacing the separate vps-ssh-key-manager package ([SSH keys](docs/tools/ssh-keys.md)).
- **`fixkeys.sh` 2.0** for console recovery: `list|add|remove|perms|diagnose|restore|menu`, `--user`, `--file`,
  `--root DIR` for rescue-mounted disks, `ssh-keygen` validation, refuses private keys, effective
  `AuthorizedKeysFile` from `sshd -T`, backups, atomic writes, audit with fingerprints only.
  [Lockout recipe](docs/recipes/recover-ssh-lockout.md).

### Added (docs)

- [Database environments](docs/database-environments.md), [Backups and recovery](docs/backups-and-recovery.md),
  [High availability](docs/high-availability.md), [Lessons learned](docs/lessons-learned.md),
  [checklists](docs/checklists/README.md); reference pages for [privileges](docs/reference/privileges.md),
  [naming](docs/reference/naming.md), [sizing](docs/reference/sizing.md) and
  [configuration keys](docs/reference/configuration-keys.md) (generated, checked by `make links`);
  ADRs 0008-0010 (database topology, MongoDB, least-privilege roles).

### Fixed (shell tools)

- Usage text works with BSD `sed` (`p;}`), so `--help` works on macOS.

### Added (platform APIs, CLI, Python)

- **PHP platform API library** (`php/`, `simtabi/vps-server-workbench`, PHP 8.4+): typed, fluent clients for
  DigitalOcean (droplets, snapshots, actions with `wait()`), Cloudflare (zones, DNS list/upsert/delete, token
  verify), Ploi (servers, sites, deploy) and Google Compute Engine (instances, snapshots, firewalls with a
  world-open check, operations). One PSR-18/17 transport (Guzzle by default) with timeouts, retries with
  exponential backoff and jitter (429 always, 5xx and network errors only for idempotent methods),
  `Retry-After`, pagination, refused redirects, path validation and a redacting PSR-3 logger. Typed DTOs,
  enums and exceptions. GCP auth via service-account JWT or `gcloud`, read-only scope for reads.
- **Safety model**: every write returns a `PendingAction` (`plan()` dry run, `confirm()` once); deletes are
  destructive; every dry run and write goes to a 600 JSONL audit log (`VSW_AUDIT_LOG`).
- **Credentials** from explicit value, env, or `~/.config/vps-server-workbench/credentials` (refused unless
  600, owned by you and outside any git tree); `Secret` type and redaction keep tokens out of output.
- **`bin/workbench`** (was `bin/vsw`): `do`, `cf`, `ploi`, `gcp`, `credentials`, `version` on the PHP core
  with `--dry-run`, `--yes`, `--force` (destructive), `--json`, `--verbose` and exit codes 0-4; `py` for the
  Python package; `<area> <tool>` for shell tools.
- **Python package** (`python/`, standard library only): `ping` TCP probe with an env-file reader and tests.
- `make php` (Pint, PHPStan level max with strict rules, PHPUnit), `make python`, advisory `make fmt-check`;
  CI installs PHP 8.4 and Python 3.14. Smoke tests cover the dispatcher, shims and CLI safety exits.
- Docs: installation, configuration, release checklist, CLI, platform API and Python references, ADRs
  0001-0005.

### Changed (docs layout)

- Docs follow the other Simtabi packages: guides at the top of `docs/`, tool references in `docs/tools/`,
  recipes in `docs/recipes/`, decisions in `docs/adr/`. Old to new paths are listed in `docs/structure.md`.
- The rollout recipe and the reference example run `doctl auth init` on its own line (it prompts for the
  token, so a pasted block would feed it the next line) and show the `bin/workbench do snapshot` alternative.

### Changed (project renamed: vps-server-workbench)

- The project is now **`simtabi/vps-server-workbench`** (was `vps-hosting-management`): the repository folder,
  README, badges, Makefile and docs use the new name. Entries below this one describe the project under its
  old name and are left as written. Nothing changes on servers: the manager is still installed as
  `/root/docker-db-server-manager.sh` and its config as `/etc/docker-db-server-manager.conf`.

### Added (manager 1.3.0, guided upgrade)

- `upgrade` (alias `apply`): one guided, self-healing rollout on a live server. Preflight (config validation:
  IPv4, CIDR, ports and duplicates, names, pinned images, no `:latest`; disk, Docker, container health, public
  bindings), diff plan (`--dry-run`), DigitalOcean snapshot offer (`--snapshot` via API token on the server,
  `--snapshot-taken`, `--no-snapshot`), verified backup, savepoint in `upgrade-saves/<ts>` (previous manager,
  config, compose, `.env`, PgBouncer config, pinned `:pre-upgrade` image), confirm, apply, verify + doctor,
  automatic rollback of files and containers with re-verify. Data restore stays a separate confirmed command.
- TTY-aware prompts with validation; `--non-interactive` never prompts and fails safe.
- Lock for all mutating commands (stale-lock recovery); redacted run log `/var/log/docker-db-server-manager.log` (chmod 600).
- `remote-run.sh`: keeps the previous manager and config as `*.prev`; offers a doctl snapshot from the Mac before `upgrade`.
- `tests/upgrade-it.sh` / `make it`: Docker integration test (install, dry run, happy path, idempotency, forced
  failure + rollback, invalid config, lock conflict, log redaction).

### Fixed (1.3.0)

- The pgvector image build failed: the pgdg repo was switched to https before `ca-certificates` was installed.
- `doctor` no longer fails where `ss` is missing (falls back to `lsof`, else reports unknown).
- `install` validates the config first.
- The run log is flushed before exit, so the final error line is never lost.

### Changed (1.3.0)

- Rollout plan, db-server.md, upgrading.md and the example README use `upgrade` instead of manual backup/copy/install steps.

### Added (manager 1.2.0, connections)

- Optional Adminer web UI: `ENABLE_ADMINER` (default 0), `ADMINER_IMAGE=adminer:6.1.2-standalone` (pinned),
  `ADMINER_PORT=8081`. Published on `127.0.0.1` only (never the private IP, no ufw rule), read-only container,
  `no-new-privileges`; `doctor` fails if it listens anywhere but loopback.
- User management: `create-user`, `grant`, `rotate-password`, `list-dbs`, `list-users`, `drop-db`, `drop-user`
  (type DROP). Least privilege: per-database read-write or `--readonly`; `create-db --readonly-user`;
  `PUBLIC` loses CONNECT on new databases and `PG_DB`; protected bootstrap users and system DBs. Passwords
  from `openssl rand`, sent to the client on stdin (never in `ps`), printed once or `--out FILE` (chmod 600).
- `create-db --extensions a,b` (pgvector, PostGIS, citext, hstore...); `citext` added to `PG_EXTENSIONS`.
- `docs/runbooks/rollout-plan.md`: dry run, backup, rollback copies, install, verify, rollback; project checklist updated.

### Fixed

- `create-db` users could not log in through PgBouncer: PgBouncer now uses `AUTH_USER=PG_USER` + `auth_query`,
  and the manager sends `RELOAD` after user changes (status gap 5 closed).

### Added (continued)

- `scripts/local/db-tunnel.sh`: SSH tunnels per engine (`postgres pgbouncer mysql mariadb adminer all`).
- `docs/connections.md`: Mac GUI tools over SSH with real ports (5432, 6432, 3306, 3307), web to DB, PgBouncer vs
  direct for migrations, Redis, off-site backups, GitHub deploy key, mail, monitoring, VPC-only ufw, admin UI
  comparison, MongoDB decision (not needed; no toggle). Linked from docs/README and security.md.

### Changed (project-neutral core)

- The core scripts, configs and docs no longer assume any one project. Project names live only in
  `examples/`; `make test` fails if one appears in a core file.
- `ploi-deploy.sh` rewritten: `PRESET=laravel|generic`; optional hooks `FIRST_INSTALL_CMD`, `INSTALL_ENV_KEYS`,
  `MIGRATE_CMD`, `EXTRA_MIGRATE_CMDS`, `BUILD_CMDS`, `POST_DEPLOY_CMDS`, `HEALTHCHECK_CMD` (all empty by default);
  `ENV_DEFAULTS` replaces `TENANCY_DOMAIN_KEY`. Removed `INSTALL_COMMAND`, `INSTALL_NEEDS_ADMIN`, `TENANTS_MIGRATE`,
  `DOCTOR_COMMAND` (see `examples/generic-laravel/ploi-deploy.settings.sh` for the mapping). Works on in-place sites too,
  links `<site>/.env` to the shared file for Ploi's editor, enforces `chmod 600`, composer/npm steps only when
  `composer.json`/`package.json` exist, first-install marker in the shared dir (old `storage/installed` honoured).
- Defaults: `APP_SUBDIR=.`, `PHP_MIN=8.3.0`, no Node version check unless `NODE_MIN_MAJOR` is set.

### Added (manager 1.1.0)

- `ENABLE_POSTGRES/PGBOUNCER/MYSQL/MARIADB` toggles; `PG_EXTENSIONS`; `init`, `create-db`, `doctor`, `env [engine]`.
- Backups: free-space check (`MIN_FREE_MB`), atomic `.partial` directory, `chmod 700`, MySQL/MariaDB users and grants,
  `BACKUP_HOOK` for offsite copies, logrotate entry from `cron-install`.
- `scripts/web/check-db-reach.sh`; `update-env-db.sh` keeps only `KEEP_BACKUPS` `.env.bak.*` copies (umask 077).
- Docs: getting started ("new project in 10 minutes"), security and operations (Docker bypasses ufw, updates,
  secrets on disk, logs, monitoring), status (done vs open); `examples/generic-laravel/`.
- Tests: engine toggles, `init`, `create-db` name check, `.bak` pruning, deploy sandbox, project-neutral core.

### Added (docs and tooling)

- `docs/web-server-caddy.md`: Caddy on a Ploi Docker server, end to end (DNS, ports/ufw, files in
  `/home/ploi/containers/<name>`, Ploi panel vs scp, Caddyfile, validate, reload, logs, staging vs prod, troubleshooting).
- `compose/caddy` rewritten as a Laravel stack: caddy + php-fpm `app` + `queue` + `scheduler`, `conf/` folder mount,
  persistent `caddy_data`, `php/Dockerfile`, `ACME_CA` switch, `variants/` (reverse proxy, whoami smoke test under
  the `smoke` profile).
- Mermaid diagrams: architecture, request flow, Caddy stack, deploy pipeline, DB command lifecycle, backup/restore,
  upgrade procedure, SSH key flow, "which machine am I on?". Port, settings and command reference tables.
- `docs/README.md` index, `docs/upgrading.md` (moving an existing server to this version).
- `tests/check-links.py` + `make links`; `tests/render-mermaid.sh` + `make mermaid`; `make compose-check` now also runs
  `caddy validate` on every Caddyfile; `make ci` = lint + smoke + links + compose-check.

### Fixed

- Deploy script required `TENANCY_CENTRAL_DOMAINS` for every app; `REQUIRED_VARS` and `TENANCY_DOMAIN_KEY` are now
  settings (a project example sets both). `env_set` escapes `|`, `&` and `\` in values.
- A project example ran `reset --yes` against a server with data; now `status, verify` then `install`.
- The Caddy example mounted the Caddyfile as a single file (edits not seen after reload) and proxied to whoami only.
- Config example pinned `BACKUP_DIR`/`WEB_ENV` values that disagreed with derived defaults.
- Docs: `verify` description (direct login is via `127.0.0.1:5432`), unverifiable Ploi menu paths reworded, daemon
  directory wording, DB-role note for sshmgr.

### Added

- **Docker DB Server Setup Manager** (`scripts/db/docker-db-server-manager.sh`), imported from the version verified on
  the reference DB server: PostgreSQL 18 + PostGIS 3.6 + pgvector (7 extensions in `template1` and the app DB),
  PgBouncer 1.26.1 in session mode with scram, MySQL 9.7, MariaDB 13, all bound to the private VPC IP with ufw
  limited to the VPC range. `verify` reaches PgBouncer over the Docker network because ufw drops the
  container-to-host-private-IP hairpin.
- Manager configuration: every name, port, image and path is a variable, read from the environment, then
  `--config FILE` / `DBM_CONFIG` / `/etc/docker-db-server-manager.conf`, then defaults. Non-secret compose settings
  are written to `$DB_DIR/stack.env`. New `EXPECTED_PRIVATE_IP` wrong-server guard, `--version`.
- `scripts/db/remote-run.sh`: run the manager from a workstation with an IP guard and one sudo prompt.
- `scripts/web/update-env-db.sh`: idempotent `DB_*` update of a shared Laravel `.env` with backup and masked output,
  locally or over SSH.
- `scripts/deploy/ploi-deploy.sh`: Ploi zero-downtime deploy script, with a SETTINGS block for site, branch, app
  directory, PHP/Node minimums, install and doctor commands, tenant migrations.
- Caddy reverse-proxy compose example, config templates, a generic Laravel example, the Ploi/DO plan finder tool.
- Docs: architecture, DB server runbook, web server, deploy, daemons, SSH access, troubleshooting.
- Makefile (`lint`, `test`, `ci`) and a GitHub Actions workflow running shellcheck and `bash -n`.

### Changed

- Defaults are generic (`PG_USER`/`PG_DB` `app`, `VPC_CIDR` `10.0.0.0/8`, no fallback private IP). Existing installs
  must set the old values in the config file; see `docs/upgrading.md`.
