# Examples

One folder per project. Each holds only that project's settings (no secrets):
the DB manager config, the deploy SETTINGS block and anything else specific.
The scripts in `shell/` (and the `php/` and `python/` packages) stay project-neutral.

| Folder | What |
|---|---|
| [`generic-laravel/`](generic-laravel/README.md) | made up: Postgres-only DB server, zero-downtime Laravel site at `app.example.com` |
| [`myapp/`](myapp/README.md) | a real deployment: all four engines, in-place multi-tenant Laravel site, admin install command |

New project: copy `generic-laravel/` to `examples/<yourproject>/` and follow
[docs/getting-started.md](../docs/getting-started.md).
