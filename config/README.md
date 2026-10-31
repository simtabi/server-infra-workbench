# config/

`*.example` templates, one per tool. They hold **no secrets, ever**: copy a template **outside** this
repository (or to the server), fill it in, and `chmod 600` it.

| Template | For | Copy to |
|---|---|---|
| [`db-server.env.example`](db-server.env.example) | the DB server manager | `/etc/docker-db-server-manager.conf` on the DB server |
| [`web-db.env.example`](web-db.env.example) | `src/shell/web/update-env-db.sh` | next to the site's `.env` on the web server |
| [`laravel.env.example`](laravel.env.example) | `bin/workbench env init\|check` | never copied by hand: `env init` writes the site's `.env` (600) from it |
| [`credentials.env.example`](credentials.env.example) | `bin/workbench do\|cf\|ploi\|gcp\|keys` | `~/.config/vps-server-workbench/credentials` (`install -m 600 /dev/null` first) |
| [`addons.conf.example`](addons.conf.example) | `bin/workbench addon` | `/etc/vps-server-workbench/addons.conf`; `configure` writes `local/<client>/addons-<role>.conf` |
| [`profiles/`](profiles/) | `bin/workbench configure\|profile` | used in place; overrides go in `local/<client>/` |
| [`ploi-do-plan-finder.env.example`](ploi-do-plan-finder.env.example) | `bin/workbench plans` | e.g. `~/.config/vps-server-workbench/plans.env`, then `--env-file` |

Platform API tokens for `bin/workbench do|cf|ploi|gcp` go in the environment or in
`~/.config/vps-server-workbench/credentials` (0600): see [configuration.md](../docs/configuration.md).
