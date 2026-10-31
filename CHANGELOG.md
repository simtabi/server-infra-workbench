# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- `docs/runbooks/rollout-plan.md`: dry run, backup, rollback copies, install, verify, rollback; myapp checklist updated.

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
  `DOCTOR_COMMAND` (see `examples/myapp/ploi-deploy.settings.sh` for the mapping). Works on in-place sites too,
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
- `docs/README.md` index, `docs/upgrading.md` (moving an existing server to this version, myapp commands).
- `tests/check-links.py` + `make links`; `tests/render-mermaid.sh` + `make mermaid`; `make compose-check` now also runs
  `caddy validate` on every Caddyfile; `make ci` = lint + smoke + links + compose-check.

### Fixed

- Deploy script required `TENANCY_CENTRAL_DOMAINS` for every app; `REQUIRED_VARS` and `TENANCY_DOMAIN_KEY` are now
  settings (the myapp example sets both). `env_set` escapes `|`, `&` and `\` in values.
- myapp example ran `reset --yes` against a server with data; now `status, verify` then `install`.
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
- Caddy reverse-proxy compose example, config templates, the myapp example, the Ploi/DO plan finder tool.
- Docs: architecture, DB server runbook, web server, deploy, daemons, SSH access, troubleshooting.
- Makefile (`lint`, `test`, `ci`) and a GitHub Actions workflow running shellcheck and `bash -n`.

### Changed

- Defaults are generic (`PG_USER`/`PG_DB` `app`, `VPC_CIDR` `10.0.0.0/8`, no fallback private IP). Existing installs
  must set the old values in the config file; see `examples/myapp/README.md`.
