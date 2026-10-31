# Installation

The workbench runs on your **workstation** (macOS or Linux). Servers need nothing from this repo except what
the tools upload or paste for you (the DB manager, the deploy script, the Caddy stack).

## Requirements

| For | Needs | Check |
|---|---|---|
| Shell tools | bash 4+ (`update-env-db.sh` also runs on macOS bash 3.2), `ssh`, `curl` | `bash --version` |
| Platform APIs (`do`, `cf`, `ploi`, `gcp`) | PHP 8.4+ with `json` and `openssl`, Composer 2 | `php -v`, `composer -V` |
| Python helpers | Python 3.12+ | `python3 --version` |
| Development | shellcheck, docker (compose checks), optional shfmt, ruff, pre-commit | `make help` |
| Snapshots from `remote-run.sh` (optional) | doctl | `doctl version` |
| GCP without a key file (optional) | gcloud | `gcloud --version` |

On macOS with Homebrew:

```bash
brew install bash shellcheck shfmt jq php composer python doctl
```

## Get the code

```bash
git clone <your remote or path> vps-server-workbench
cd vps-server-workbench
composer install --working-dir=php       # only for the platform APIs
bin/workbench list                       # every tool and where it lives
```

Optional, to type `workbench` anywhere:

```bash
mkdir -p ~/.local/bin && ln -sf "$PWD/bin/workbench" ~/.local/bin/workbench
```

## Credentials (platform APIs only)

Shell tools use your SSH config and never need API tokens. The platform commands read tokens from the
environment or from a private file; set them up as described in [configuration](configuration.md#platform-credentials),
then check:

```bash
bin/workbench credentials                # shows env / file / missing per key, never the values
```

If you use doctl for snapshots, run `doctl auth init` **on its own line**: it prompts for the token, and a pasted
block of commands would feed it the next line instead.

## Verify the install

```bash
make ci        # lint, smoke tests, PHP and Python checks, links, compose checks (skips what is not installed)
```

Next: [Getting started](getting-started.md).
