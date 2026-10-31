# simtabi/vps-server-workbench

[![CI](https://img.shields.io/github/actions/workflow/status/simtabi/vps-server-workbench/ci.yml?branch=main&label=ci)](https://github.com/simtabi/vps-server-workbench/actions/workflows/ci.yml)
[![PHP](https://img.shields.io/badge/php-8.4%2B-777bb4.svg)](src/php/composer.json)
[![PHPStan](https://img.shields.io/badge/phpstan-level%20max-brightgreen.svg)](src/php/phpstan.neon)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> Tools and runbooks for hosting PHP (Laravel or not) apps on DigitalOcean droplets managed with Ploi: a
> dedicated Docker database server on the private VPC, a Ploi web server, zero-downtime deploys, daemons,
> SSH access, and typed API clients for DigitalOcean, Cloudflare, Ploi and Google Compute Engine.

Server tooling is plain Bash plus docker compose; platform automation is a small PHP 8.4 library with a CLI.
Every name, path, IP, port and image version is a parameter with a default; project-specific values live
only in [`examples/`](examples).

## Install

```bash
git clone <your remote or path> vps-server-workbench && cd vps-server-workbench
composer install --working-dir=src/php        # only needed for the platform APIs (PHP 8.4+)
bin/workbench list                        # every tool and where it lives
```

Requirements and credentials: [docs/installation.md](docs/installation.md).

## Quick start

A database server for a new project, from your workstation:

```sh
# 0. SSH: one key per host (see docs/recipes/set-up-ssh-access.md), add the .pub in Ploi for user ploi
sshmgr host apply myproject prd-db-00 203.0.113.20 ploi db --reconcile
ssh prd-db-00 whoami                                  # -> ploi

# 1. Config for the DB server (no secrets in it): detects the private IP and VPC
ssh prd-db-00 'bash -s -- init' < src/shell/db/docker-db-server-manager.sh > my-db-server.conf
#    edit PG_USER / ENABLE_* ... (or start from config/db-server.env.example)

# 2. Install + guard + backups + DB_* lines
src/shell/db/remote-run.sh --host prd-db-00 --expect-ip 10.0.0.5 \
  --config my-db-server.conf -- install, cron-install, env

# 3. Save the printed DB_* lines as db.env (never commit it), put them on the web server, redeploy
src/shell/web/update-env-db.sh --remote prd-web-00 --site example.com --from db.env
```

Platform APIs, read-only unless you confirm:

```bash
bin/workbench credentials                                         # which tokens are set (never the values)
bin/workbench do droplets --tag db
bin/workbench do snapshot 123456 --name db-pre-upgrade --dry-run  # shows the request, sends nothing
bin/workbench do snapshot 123456 --name db-pre-upgrade --yes --wait
bin/workbench cf dns upsert example.com A db 203.0.113.10 --ttl 300 --dry-run
bin/workbench ploi deploy 42 1001 --yes
bin/workbench gcp firewalls --project my-project                  # flags rules open to 0.0.0.0/0
```

```php
use Simtabi\VpsServerWorkbench\DigitalOcean\DigitalOcean;

$action = DigitalOcean::make()->droplets()->snapshot(123456, 'db-pre-upgrade'); // nothing sent yet
$action->plan();                 // dry run
$action->confirm()->wait();      // send, then poll until done
```

New project end to end: **[Getting started](docs/getting-started.md)** (about 10 minutes).

## Why

- **Safe on live servers.** The DB manager's `upgrade` previews a diff, takes a verified backup and a
  savepoint, applies, verifies and rolls back by itself; `remote-run.sh` refuses to run on the wrong host.
  Platform writes are pending actions that need an explicit confirm, with dry runs and an audit log.
- **No secrets in the repo, by construction.** Tokens come from the environment or a chmod 600 file outside
  any git tree; logs and errors are redacted; the smoke tests scan for leaked passwords.
- **Parameters, not forks.** One toolkit for every project; per-project values are small files in `examples/`.
- **Tested offline.** shellcheck, smoke tests, a Docker integration test of the upgrade, PHPStan at level
  max and PHPUnit on a mock HTTP client; no real API is called in tests.

## What's here

| Path | What |
|---|---|
| [`bin/workbench`](bin/workbench) | One entry point: `list`, `<area> <tool>` for shell tools, `do`/`cf`/`ploi`/`gcp` for platform APIs, `py` for Python helpers ([cli.md](docs/tools/cli.md)) |
| [`src/shell/db/docker-db-server-manager.sh`](src/shell/db/docker-db-server-manager.sh) | Docker DB Server Setup Manager: PostgreSQL 18 + PostGIS 3.6 + pgvector, PgBouncer (session, scram), MySQL 9.7, MariaDB 13, bound to the private IP, each engine optional. `init install upgrade reset status verify doctor env create-db create-user grant rotate-password list-dbs list-users drop-db drop-user logs backup restore tls-ca monitor-user metrics migrate-managed pg-major-upgrade cron-install cron-remove uninstall help` |
| [`src/shell/db/remote-run.sh`](src/shell/db/remote-run.sh) | Run the manager on the DB server from your workstation, with a wrong-server guard |
| [`src/shell/web/update-env-db.sh`](src/shell/web/update-env-db.sh) | Back up a shared Laravel `.env` and replace its `DB_*` keys idempotently (password masked in output); local or `--remote` |
| [`src/shell/deploy/ploi-deploy.sh`](src/shell/deploy/ploi-deploy.sh) | Ploi deploy script for any PHP/Node app: `laravel` or `generic` preset, optional hooks (first install, migrations, post-deploy, health check), zero-downtime or in-place |
| [`src/shell/tunnels/db-tunnel.sh`](src/shell/tunnels/db-tunnel.sh) | SSH tunnels from the Mac per engine (`postgres pgbouncer mysql mariadb adminer all`) for TablePlus, psql, Adminer |
| [`src/shell/web/check-db-reach.sh`](src/shell/web/check-db-reach.sh) | TCP check from the web server to every DB port (no passwords needed), with region and VPC warnings |
| [`src/shell/server/`](docs/tools/server.md) | `server init`, `harden`, `update --reboot-window`, `inventory`, and `web diagnose` for a 500/503 |
| [`src/shell/env/env.sh`](docs/tools/env.md) | Laravel `.env` per environment: `env init` / `env check` from the template, `--addons` merges add-on keys |
| [`src/shell/ssh/fixkeys.sh`](docs/tools/ssh-keys.md) | `authorized_keys` repair and console lockout recovery (also from the DO recovery ISO) |
| [`src/shell/net/wireguard.sh`](docs/tools/net.md) | WireGuard tunnel between two servers in different regions ([cross-region](docs/cross-region.md)) |
| [`src/shell/monitor/monitor.sh`](docs/tools/monitor.md) | Self-hosted monitoring per node: Beszel, Uptime Kuma, Netdata, Prometheus + Grafana + exporters; loopback UIs, RAM gate. `bin/workbench status` for a one-screen health check |
| [`src/shell/addons/addon.sh`](docs/tools/addons.md) | Optional services: Gotenberg (PDF) and one S3-compatible store (Garage, SeaweedFS, RustFS) |
| [`configure`](docs/configure.md) | `bin/workbench configure` wizard and versioned `config/profiles` (dev-budget and others) into gitignored `local/<client>/` |
| [`src/php`](src/php/README.md) | Typed PHP 8.4 clients for DigitalOcean, Cloudflare, Ploi and GCP on PSR-18, with retries, pagination, redaction, pending actions and an audit log ([platform-api.md](docs/tools/platform-api.md)) |
| [`src/python`](src/python/README.md) | Standard-library helpers with tests: `ping` (TCP probe) and `plans` (which DO plans each region offers through Ploi) ([python.md](docs/tools/python.md)) |
| [`stacks/caddy`](stacks/README.md) | Laravel (php-fpm, queue, scheduler) behind Caddy with automatic HTTPS, for a Ploi Docker web server; reverse-proxy and smoke-test variants |
| [`config/`](config/README.md) | `.env.example`-style templates for every tool |
| [`examples/`](examples/README.md) | Example configs per project (no secrets): a made-up generic Laravel app (real setups live in gitignored `local/`) |

Full map and conventions: [docs/structure.md](docs/structure.md).

## Documentation

Start at the [docs index](docs/README.md) (diagrams and command reference included).

**Guides:** [Installation](docs/installation.md) · [Getting started](docs/getting-started.md) ·
[Configuration](docs/configuration.md) · [Architecture](docs/architecture.md) ·
[Repository structure](docs/structure.md) · [Security and operations](docs/security.md) ·
[Troubleshooting](docs/troubleshooting.md) · [Status](docs/status.md) · [Releasing](docs/release.md)

**Reference:** [DB server manager](docs/tools/db-server-manager.md) · [Deploy script](docs/tools/deploy-script.md)
(including the Ploi placeholder caveat) · [Caddy stack](docs/tools/caddy-stack.md) ·
[Command line](docs/tools/cli.md) · [Platform API library](docs/tools/platform-api.md) ·
[Python package](docs/tools/python.md)

**Recipes:** [Set up SSH access](docs/recipes/set-up-ssh-access.md) ·
[Configure a Ploi web server](docs/recipes/configure-a-ploi-web-server.md) ·
[Run daemons](docs/recipes/run-daemons.md) · [Connect to databases](docs/recipes/connect-to-databases.md) ·
[Upgrade a legacy DB server](docs/recipes/upgrade-a-legacy-db-server.md) ·
[Roll out a manager upgrade](docs/recipes/roll-out-a-manager-upgrade.md)

**Decisions:** [Architecture decision records](docs/adr/README.md)

## Development

```sh
make help           # targets
make lint           # shellcheck + bash -n on every script
make test           # offline smoke tests (shell tools, dispatcher, CLI safety)
make php            # pint --test, phpstan (level max), phpunit
make python         # py_compile (+ ruff when installed), unittest
make links          # check relative links and #anchors in all Markdown
make compose-check  # docker compose config + caddy validate
make ci             # all of the above (what CI runs)
make it             # Docker integration test of the guided DB upgrade (~3 min)
make fmt-check      # shfmt diff (advisory)
```

Requires bash 4+ (`update-env-db.sh` also runs on macOS bash 3.2), python3,
[shellcheck](https://www.shellcheck.net/), PHP 8.4+ with Composer for the PHP checks, and docker for the
compose checks. Missing PHP, Python or docker makes the matching targets skip with a note.

## Stability

The shell tools and the DB manager (1.3.0) are used on production servers; their commands and flags change
only with a changelog entry (the pre-release `scripts/` paths are gone, see
[structure](docs/structure.md#old-to-new-paths)). The
PHP library and CLI are **0.x**: the API may still change in a minor release, always noted in the
[changelog](CHANGELOG.md). See [releasing](docs/release.md).

## Contributing & security

Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Please report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md), not in public issues.

## License

MIT © Simtabi LLC. See [LICENSE](LICENSE).
