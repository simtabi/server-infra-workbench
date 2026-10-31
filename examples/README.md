# Examples

Generic, made-up examples only (`example.com`, `db-01`/`web-01`, `10.0.0.5`, documentation IPs
`203.0.113.x`). Real deployments belong in [`local/`](../local/README.md), which git ignores, so no
client hosts, IPs, domains or names ever reach the repository. `make client-check` enforces that.

| Folder | What |
|---|---|
| [`generic-laravel/`](generic-laravel/README.md) | made up: Postgres-only DB server, zero-downtime Laravel site at `app.example.com` |

New project: `cp -R examples/generic-laravel local/<yourproject>` and follow
[docs/getting-started.md](../docs/getting-started.md).
