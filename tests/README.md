# tests/

Repository-level tests. Package tests live with their package (`src/php/tests`, `src/python/tests`).
No test calls a real API or a real server.

| Folder | What | Run |
|---|---|---|
| [`shell/smoke.sh`](shell/smoke.sh) | every shell tool: syntax, `--help`, dry runs, validation, mocked PATH stubs | `make test` |
| [`shell/deploy-sandbox.sh`](shell/deploy-sandbox.sh) | the deploy script against a throwaway git site | `make test` |
| [`shell/smoke-db.sh`](shell/smoke-db.sh) | DB manager functions (env-init, privileges, engines) | `make test` |
| [`shell/smoke-addons.sh`](shell/smoke-addons.sh) | add-on planner and validation | `make test` |
| [`shell/smoke-server.sh`](shell/smoke-server.sh) | server init/harden/update/inventory, web diagnose, env init/check, ssh fixkeys against a fake root (`VSW_SYSROOT`) + stubs | `make test` |
| [`shell/client-check.sh`](shell/client-check.sh) | no client name, IP or domain in tracked files or commit messages | `make client-check` |
| [`shell/upgrade-it.sh`](shell/upgrade-it.sh) | the DB manager on real containers (docker) | `make it` |
| [`shell/addons-it.sh`](shell/addons-it.sh) | add-ons on real containers (docker) | `make it` |
| [`shell/server-it.sh`](shell/server-it.sh) | server init/harden/inventory/update, env, fixkeys as root in Ubuntu 24.04 (docker) | `make it` |
| [`docs/check-links.py`](docs/check-links.py) | every relative Markdown link resolves | `make links` |
| [`docs/render-mermaid.sh`](docs/render-mermaid.sh) | every Mermaid diagram renders | `make mermaid` |

`make ci` is the gate: lint, tests, PHP, Python, links and compose checks.
