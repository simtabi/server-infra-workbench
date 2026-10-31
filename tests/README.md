# tests/

Repository-level tests. Package tests live with their package (`src/php/tests`, `src/python/tests`).
No test calls a real API or a real server.

| Folder | What | Run |
|---|---|---|
| [`shell/smoke.sh`](shell/smoke.sh) | every shell tool: syntax, `--help`, dry runs, validation, mocked PATH stubs | `make test` |
| [`shell/deploy-sandbox.sh`](shell/deploy-sandbox.sh) | the deploy script against a throwaway git site | `make test` |
| [`shell/smoke-db.sh`](shell/smoke-db.sh) | DB manager functions (env-init, privileges, engines) | `make test` |
| [`shell/smoke-addons.sh`](shell/smoke-addons.sh) | add-on planner and validation | `make test` |
| [`shell/smoke-net.sh`](shell/smoke-net.sh) | `net wireguard` setup/status/remove on two fake roots with stub `wg`/`ufw`/`systemctl` | `make test` |
| [`shell/smoke-server.sh`](shell/smoke-server.sh) | server init/harden/update/inventory, web diagnose, env init/check, ssh fixkeys against a fake root (`VSW_SYSROOT`) + stubs | `make test` |
| [`shell/client-check.sh`](shell/client-check.sh) | no client name, IP or domain in tracked files or commit messages | `make client-check` |
| [`shell/upgrade-it.sh`](shell/upgrade-it.sh) | the DB manager on real containers (docker) | `make it` |
| [`shell/addons-it.sh`](shell/addons-it.sh) | add-ons on real containers (docker) | `make it` |
| [`shell/server-it.sh`](shell/server-it.sh) | server init/harden/inventory/update, env, fixkeys as root in Ubuntu 24.04 (docker) | `make it` |
| [`shell/db-features-it.sh`](shell/db-features-it.sh) | verify-full TLS, metrics, migrate-managed, the Postgres major upgrade (docker) | `make it` |
| [`shell/pitr-it.sh`](shell/pitr-it.sh) | pgBackRest backup and point-in-time restore (docker) | `make it` |
| [`shell/pitr-s3-it.sh`](shell/pitr-s3-it.sh) | PITR through an S3 repo: Garage add-on behind a Caddy TLS front with a per-run CA, encrypted repo, restore to a time (docker) | `make it` |
| [`shell/garage-cluster-it.sh`](shell/garage-cluster-it.sh) | three Garage nodes in host networking, replication 3, joins, one node down (docker) | `make it` |
| [`shell/monitor-it.sh`](shell/monitor-it.sh) | the monitoring stacks and exporters against a real manager install (docker) | `make it` |
| [`shell/wg-it.sh`](shell/wg-it.sh) | a real WireGuard tunnel between two Ubuntu containers (ssh, ufw); SKIP without kernel WireGuard | `make it` |
| [`shell/smoke-monitor.sh`](shell/smoke-monitor.sh), [`shell/smoke-progress.sh`](shell/smoke-progress.sh) | monitor planner, progress output | `make test` |
| [`../examples/run.sh`](../examples/run.sh) | every example's `example.conf`: configure dry run + plans | `make test` |
| [`security/no-hardcoded-secrets.py`](security/no-hardcoded-secrets.py) | no literal password, token or URL credentials in tracked files (plus gitleaks, full history) | `make secrets-check` |
| [`docs/check-commands.py`](docs/check-commands.py) | every documented command, subcommand and `--flag` exists in the tool's `--help` | `make docs-commands` |
| [`../src/php/tests/Integration`](../src/php/tests/Integration) | DO, Ploi, Cloudflare, GCP clients against a local mock HTTP server through real Guzzle | `make php` |
| [`docs/check-links.py`](docs/check-links.py) | every relative Markdown link resolves | `make links` |
| [`docs/gen-config-keys.py`](docs/gen-config-keys.py) | `docs/reference/configuration-keys.md` matches `config/db-server.env.example` (`--check`; run without it to regenerate) | `make links` |
| [`docs/render-mermaid.sh`](docs/render-mermaid.sh) | every Mermaid diagram renders | `make mermaid` |

`make ci` is the gate: secrets, lint (pinned shellcheck), tests, client check, PHP, Python, links, documented
commands and compose checks. `make ci-local` runs it exactly as CI does. `make it` runs the docker suites one
after another (`tests/shell/run-suites.sh`).
