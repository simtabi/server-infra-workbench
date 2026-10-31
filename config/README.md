# config/

`*.example` templates, one per tool. They hold **no secrets, ever**: copy a template **outside** this
repository (or to the server), fill it in, and `chmod 600` it.

| Template | For | Copy to |
|---|---|---|
| [`db-server.env.example`](db-server.env.example) | the DB server manager | `/etc/docker-db-server-manager.conf` on the DB server |
| [`web-db.env.example`](web-db.env.example) | `src/shell/web/update-env-db.sh` | next to the site's `.env` on the web server |
| [`ploi-do-plan-finder.env.example`](ploi-do-plan-finder.env.example) | `bin/workbench plans` | e.g. `~/.config/vps-server-workbench/plans.env`, then `--env-file` |

Platform API tokens for `bin/workbench do|cf|ploi|gcp` go in the environment or in
`~/.config/vps-server-workbench/credentials` (0600): see [configuration.md](../docs/configuration.md).
