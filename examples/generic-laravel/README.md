# Example: a generic Laravel app

A made-up project to show the toolkit on a new app: `app.example.com` on one
Ploi web server, a Postgres-only DB server at `10.0.0.5` in the VPC
`10.0.0.0/20`, SSH aliases `myproject-web` and `myproject-db`. Nothing here is
real; copy the folder to `local/<yourproject>/` (git ignores it) and edit.

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh generic-laravel`: the same settings through `configure --dry-run` |
| [`db-server.conf`](db-server.conf) | `/etc/docker-db-server-manager.conf` (Postgres + PgBouncer only) |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | the SETTINGS block for the deploy script |

Step by step: [docs/getting-started.md](../../docs/getting-started.md).
