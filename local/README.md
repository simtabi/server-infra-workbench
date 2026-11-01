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

Start from the tracked, generic example:

```bash
cp -R examples/generic-laravel local/myapp
$EDITOR local/myapp/db-server.conf
src/shell/db/remote-run.sh --host db-01 --expect-ip 10.0.0.5 --config local/myapp/db-server.conf -- status, verify
```

Rules:

- No secrets here either: passwords live on the server (`docker-db-server-manager.sh env`) and API
  tokens in `~/.config/server-infra-workbench/credentials` (chmod 600).
- Client identifiers (names, hosts, IPs, domains) go in `.client-denylist` at the repo root (also
  ignored). `make client-check` fails if any of them shows up in a tracked file.
