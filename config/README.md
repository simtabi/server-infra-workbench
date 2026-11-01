# config/

`*.example` templates, one per tool. They hold **no secrets, ever**: copy a template **outside** this
repository (or to the server), fill it in, and `chmod 600` it.

| Template | For | Copy to |
|---|---|---|
| [`db-server.env.example`](db-server.env.example) | the DB server manager | `/etc/docker-db-server-manager.conf` on the DB server |
| [`web-db.env.example`](web-db.env.example) | `src/shell/web/update-env-db.sh` | next to the site's `.env` on the web server |
| [`laravel.env.example`](laravel.env.example) | `bin/siwo env init\|check` | never copied by hand: `env init` writes the site's `.env` (600) from it |
| [`credentials.env.example`](credentials.env.example) | `bin/siwo do\|cf\|ploi\|gcp\|keys` | `~/.config/server-infra-workbench/credentials` (`install -m 600 /dev/null` first) |
| [`addons.conf.example`](addons.conf.example) | `bin/siwo addon` | `/etc/vsw-addons.conf` (`ADDON_CONF`); `configure` writes `local/<client>/addons-<role>.conf` |
| [`monitor.conf.example`](monitor.conf.example) | `bin/siwo monitor` | `/etc/vsw-monitor.conf` (`MONITOR_CONF`); `configure` writes `local/<client>/monitor-<role>.conf` |
| [`profiles/`](profiles/) | `bin/siwo configure\|profile` | used in place; overrides go in `local/<client>/` |
| [`ploi-do-plan-finder.env.example`](ploi-do-plan-finder.env.example) | `bin/siwo plans` | e.g. `~/.config/server-infra-workbench/plans.env`, then `--env-file` |

Platform API tokens for `bin/siwo do|cf|ploi|gcp` go in the environment or in
`~/.config/server-infra-workbench/credentials` (0600): see [configuration.md](../docs/configuration.md).
