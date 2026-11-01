# Configuration

Every tool takes its settings from, in order of precedence: **command-line flags**, then **environment
variables**, then a **config file**, then built-in defaults. Templates for every file are in
[`config/`](../config); real values for a project go in `examples/<project>/` (no secrets) or outside the repo.

## Shell tools

| Tool | Config file | Template | Reference |
|---|---|---|---|
| Configurator | `config/profiles/*.conf` layered onto `_defaults.conf`; writes `local/<client>/` | [`config/profiles/`](../config/profiles) | [configure.md](configure.md), [profiles](reference/profiles.md) |
| DB server manager | `--config FILE` locally; installed as `/etc/docker-db-server-manager.conf` (root, 600) | [`config/db-server.env.example`](../config/db-server.env.example) | [db-server-manager.md](tools/db-server-manager.md#5-configuration) |
| `update-env-db.sh`, `check-db-reach.sh` | `--from FILE` / `--env FILE` with `DB_*` lines | [`config/web-db.env.example`](../config/web-db.env.example) | [configure-a-ploi-web-server.md](recipes/configure-a-ploi-web-server.md) |
| Deploy script | the SETTINGS block at its top | [`examples/*/ploi-deploy.settings.sh`](../examples/generic-laravel/ploi-deploy.settings.sh) | [deploy-script.md](tools/deploy-script.md#settings) |
| Caddy stack | `stacks/caddy/.env` | [`stacks/caddy/.env.example`](../stacks/caddy/.env.example) | [caddy-stack.md](tools/caddy-stack.md) |

Config files are parsed as `KEY=VALUE` lines; they are never `source`d from untrusted locations. Generated
database passwords live only on the DB server (`/opt/db/.env`, 600) and in the `DB_*` lines it prints; never
commit them.

## Platform credentials

Used by `bin/workbench do|cf|ploi|gcp` and the PHP library. Resolution order, first hit wins:

1. A value passed in code (`DigitalOcean::make($token)`).
2. The environment variable.
3. The credentials file: `$SIW_CREDENTIALS_FILE`, else `~/.config/server-infra-workbench/credentials`.

| Key | What | Minimum scope |
|---|---|---|
| `DIGITALOCEAN_TOKEN` | DigitalOcean personal access token | read; add write for snapshots |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token | `Zone:Read`, plus `DNS:Edit` on the zones you change |
| `PLOI_API_TOKEN` | Ploi API token | servers and sites (read), deploy |
| `GOOGLE_APPLICATION_CREDENTIALS` | path to a service-account JSON key | `roles/compute.viewer`; add snapshot permissions for writes |
| `GCP_PROJECT` | default Google Cloud project id | (falls back to the key's `project_id`) |

Create the file (it is refused unless it is mode 600, owned by you, and outside any git working tree):

```bash
mkdir -p ~/.config/server-infra-workbench && chmod 700 ~/.config/server-infra-workbench
touch ~/.config/server-infra-workbench/credentials && chmod 600 ~/.config/server-infra-workbench/credentials
open -e ~/.config/server-infra-workbench/credentials      # macOS; or use any editor
```

Format, one key per line (quotes optional, `#` starts a comment):

```ini
# ~/.config/server-infra-workbench/credentials
DIGITALOCEAN_TOKEN=<token>
CLOUDFLARE_API_TOKEN=<token>
PLOI_API_TOKEN=<token>
GOOGLE_APPLICATION_CREDENTIALS=/Users/you/.config/gcloud/workbench-sa.json
GCP_PROJECT=my-project
```

Then `bin/workbench credentials` shows where each key comes from without printing it. Type tokens into an
editor rather than `echo`ing them, so they do not land in your shell history.

GCP without a key file: install gcloud and run `gcloud auth login`; the workbench then uses
`gcloud auth print-access-token`.

## Environment variables (platform tools)

| Variable | Default | Effect |
|---|---|---|
| `SIW_CREDENTIALS_FILE` | `~/.config/server-infra-workbench/credentials` | Credentials file location |
| `SIW_AUDIT_LOG` | `~/.local/state/server-infra-workbench/audit.log` | JSONL audit log of every dry run and write; `off` disables it |
| `SIW_KEYS_CONFIG` | `~/.config/server-infra-workbench/keys.json` | Extra SSH-key API providers for `workbench keys` (`VPSKEYS_CONFIG` also read) |
| `SIW_DROPLET_IMAGE` | `ubuntu-26-04-x64` | `do droplet-create` image when `--image` is not given; `latest` asks the API |
| `SIW_PROGRESS` | `auto` | Progress output: `auto`, `tty`, `plain` or `off` (all tools, shell included) |
| `SIW_QUIET` | unset | `1` = no progress output (what `--quiet` sets) |
| `SIW_VERBOSE` | unset | `1` = show a wrapped step's output even when it succeeds (shell tools) |

Before November 2026 these were `VSW_*` (the project was `vps-server-workbench`). An unset `SIW_X` still
falls back to `VSW_X`, with one `note: VSW_X is deprecated` line on stderr, and a credentials file or
`keys.json` that only exists under `~/.config/vps-server-workbench/` keeps being used
([ADR 0014](adr/0014-rename-to-server-infra-workbench.md)). Rename the variables and move the directory
when convenient: `mv ~/.config/vps-server-workbench ~/.config/server-infra-workbench`.

## Where things are written

| Path | What | Mode |
|---|---|---|
| `~/.local/state/server-infra-workbench/audit.log` | platform write audit (no tokens, no payloads) | 600 |
| `/var/log/docker-db-server-manager.log` (DB server) | manager run log, redacted | 600 |
| `/opt/db/` (DB server) | stack, `.env` with passwords, backups, upgrade savepoints | root |
