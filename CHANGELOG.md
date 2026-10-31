# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
