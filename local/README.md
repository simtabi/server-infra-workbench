# local/ — your own deployments (not tracked)

Everything in this folder except this README is ignored by git (see `.gitignore`). Put the
real, per-client or per-project setup here: `db-server.conf`, the `ploi-deploy.sh` SETTINGS block,
`ssh-hosts.sh`, a `web-db.env.example`, and a README with your rollout commands.

```text
local/
  README.md            <- tracked (this file)
  <project>/           <- ignored: your real hosts, IPs, domains, names
    README.md
    db-server.conf
    ploi-deploy.settings.sh
    ssh-hosts.sh
```

> **Settings moved to the repo-root `.env`.** The DB server settings that used to live in
> `local/<client>/db-server.conf` now go in the root `.env` as `SIWO_DB_<KEY>=VALUE` (template:
> [`.env-example`](../.env-example)); `remote-run.sh` and `bin/siwo db engines` turn them into the server
> config. Keep env files in the repo root only. An old `db-server.conf` here still works with
> `--config local/<client>/db-server.conf` (an explicit override), but is no longer read by default.

Start from the tracked, generic example:

```bash
cp -R examples/generic-laravel local/myapp
cp .env-example .env && chmod 600 .env && $EDITOR .env     # SIWO_DB_SSH_HOST, SIWO_DB_PRIVATE_IP, SIWO_DB_* server keys
src/shell/db/remote-run.sh -- status, verify                # host, IP, key and server config from .env
```

Rules:

- No secrets here either: passwords live on the server (`docker-db-server-manager.sh env`) and API
  tokens in `~/.config/server-infra-workbench/credentials` (chmod 600).
- Client identifiers (names, hosts, IPs, domains) go in `.client-denylist` at the repo root (also
  ignored). `make client-check` fails if any of them shows up in a tracked file.
