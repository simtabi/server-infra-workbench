# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
