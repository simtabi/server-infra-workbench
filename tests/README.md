# tests/

Repository-level tests. Package tests live with their package (`src/php/tests`, `src/python/tests`).
No test calls a real API or a real server.

| Folder | What | Run |
|---|---|---|
| [`shell/smoke.sh`](shell/smoke.sh) | every shell tool: syntax, `--help`, dry runs, validation, mocked PATH stubs | `make test` |
| [`shell/deploy-sandbox.sh`](shell/deploy-sandbox.sh) | the deploy script against a throwaway git site | `make test` |
| [`shell/upgrade-it.sh`](shell/upgrade-it.sh) | the DB manager on real containers (docker) | `make it` |
| [`docs/check-links.py`](docs/check-links.py) | every relative Markdown link resolves | `make links` |
| [`docs/render-mermaid.sh`](docs/render-mermaid.sh) | every Mermaid diagram renders | `make mermaid` |

`make ci` is the gate: lint, tests, PHP, Python, links and compose checks.
