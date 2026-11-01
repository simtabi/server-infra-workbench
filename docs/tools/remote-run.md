# remote-run.sh: run the DB manager on the DB server from your workstation

`src/shell/db/remote-run.sh` copies the manager (`src/shell/db/docker-db-server-manager.sh`) to the DB
server, checks it is the right machine (its private IP), and runs one or more manager commands there with
sudo. It is what `bin/siwo db remote-run` and `bin/siwo db engines` call.

```bash
src/shell/db/remote-run.sh [remote-run options] -- <manager command>[, <manager command>...]
```

Options **before** `--` belong to remote-run; everything **after** `--` is the manager's own command line.
That matters for `--dry-run`:

| Where | What it does | Connects? |
|---|---|---|
| `remote-run.sh --dry-run ... -- engines apply ...` | prints the ssh line, the sudo mode, what would be uploaded and the exact remote script | **no**, nothing is sent |
| `remote-run.sh ... -- engines apply ... --dry-run` | the manager's plan: it runs on the server and reads the live state, changes nothing | yes, needs sudo |

## Settings come from the repo-root `.env`

Env files live in the repo root only. The git-ignored `.env` (template [`.env-example`](../../.env-example))
is the single source of local settings; flags override it, `--env-file FILE` (or `SIWO_ENV_FILE=FILE`)
points at another root env file such as `.env.<client>`.

| `.env` key | Used as | Flag that overrides it |
|---|---|---|
| `SIWO_DB_SSH_HOST` | the ssh login: `user@public-ip` (e.g. `ploi@203.0.113.10`) or an alias from `~/.ssh/config` | `--host` |
| `SIWO_DB_SSH_IDENTITY` | private key, used alone: `ssh -i KEY -o IdentitiesOnly=yes` (scp too) | `-i` / `--identity` |
| `SIWO_DB_PRIVATE_IP` (or `SIWO_DB_EXPECTED_PRIVATE_IP`) | the wrong-server guard: the server must have this IP | `--expect-ip` |
| every other non-empty `SIWO_DB_<KEY>` | `<KEY>` in the server config (see below) | `--config FILE`, `--no-config` |

The `.env` is read line by line (`KEY=VALUE`), never sourced.

### The server config

Unless you pass `--config FILE` or `--no-config`, remote-run writes the `SIWO_DB_*` server keys (prefix
dropped) to a 600 temp file, uploads it and installs it as `/etc/docker-db-server-manager.conf` (the old one
is kept as `.prev`). Never sent: empty values, `SIWO_DB_SSH_*`, `SIWO_DB_LOCAL_*`, and any key whose name
contains `PASSWORD`, `SECRET`, `TOKEN` or `_KEY`. A `<placeholder>` still in one of those keys stops the run.
`--dry-run` lists the key names it would send (never the values).

On the server the manager reads, in this order: its environment, `/etc/docker-db-server-manager.conf`, then
`/opt/db/.env`. **`/opt/db/.env` wins** for every key it holds, so on a server whose settings live only in
`/opt/db/.env` (no `/etc` file) that file stays the live source; `engines apply` writes `ENABLE_*` into
whichever of the two files already holds the key (both when both do, `.env` when neither does), each with a
dated `.bak-*` copy.

| You want | Pass |
|---|---|
| the server config to follow your root `.env` (normal) | nothing |
| to leave the server's config files exactly as they are (e.g. a server run from `/opt/db/.env` only) | `--no-config` |
| a one-off file instead | `--config path/to/file.conf` (the old `local/<client>/db-server.conf` still works this way) |

> Upgrading from `local/<client>/db-server.conf`: copy each `KEY=VALUE` line into the root `.env` as
> `SIWO_DB_KEY=VALUE`, then check `remote-run.sh --dry-run -- status` lists the keys you expect.

## Options

| Option | Meaning |
|---|---|
| `--host H` | `user@ip` or an ssh alias. Default `SIWO_DB_SSH_HOST` |
| `-i KEY`, `--identity KEY` | private key for ssh and scp, with `IdentitiesOnly=yes`. `~` is expanded; a `.pub` or missing file is refused. Default `SIWO_DB_SSH_IDENTITY` |
| `--expect-ip IP` | the server's private IP (refuses to run elsewhere), or `skip`. Default `SIWO_DB_PRIVATE_IP` |
| `--env-file FILE` | read another root env file instead of `.env` |
| `--config FILE` / `--no-config` | see [the server config](#the-server-config) |
| `--script FILE` | upload another manager build |
| `--no-upload` | use the manager already in `/root` |
| `--sudo auto\|nopasswd\|prompt` | see [sudo](#sudo). Default `auto` |
| `--snapshot-with do\|ploi\|none` | how `upgrade`/`apply` gets its pre-change snapshot |
| `--dry-run` | print everything, connect to nothing |

## sudo

The manager needs root. With `--sudo auto` (the default) remote-run first runs `sudo -n true` over ssh,
before uploading anything:

- **passwordless** (exit 0): the commands run as they are.
- **password needed**: the run switches to `ssh -t` and sudo asks **once**, in its own prompt
  (`[sudo] password for <user> on <host>:`), right after the IP check and before anything changes. The
  password is typed into that prompt on the server; it is never put on a command line, in a file or in the
  environment. If the session has no terminal (a script, CI, a pipe, an agent), remote-run stops before
  uploading and says so: run the same command in a terminal.
- **ssh itself fails** (exit 255): it stops with the ssh error and a hint (`-i KEY`? `user@ip`?).

`--sudo prompt` skips the probe and always uses `ssh -t`; `--sudo nopasswd` skips it and never does.

## Examples

```bash
# everything from the root .env (SIWO_DB_SSH_HOST, SIWO_DB_SSH_IDENTITY, SIWO_DB_PRIVATE_IP)
src/shell/db/remote-run.sh -- status, verify

# explicit login, key and IP; first print it, then let the manager plan, then apply
src/shell/db/remote-run.sh --dry-run --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> -- engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0
src/shell/db/remote-run.sh --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> -- engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0 --dry-run
src/shell/db/remote-run.sh --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> -- engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0

# the same through siwo (reads the same .env; the engine switches come from SIWO_DB_ENABLE_*)
bin/siwo db engines plan --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip>
bin/siwo db engines apply --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip>
```

Replace every `<...>` with the real value before running it; in docs they are placeholders, in a shell
they are redirections (see below).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `zsh: no such file or directory: db-alias` (bash: `db-alias: No such file or directory`) | `<db-alias>` was typed literally. Unquoted `<` and `>` are shell redirections, so the shell tried to read a file called `db-alias` and the script never started | put the real login in: `--host <user>@<db-public-ip>` becomes e.g. `--host ploi@203.0.113.10`, or set `SIWO_DB_SSH_HOST` in `.env` and drop `--host` |
| `--host is still a placeholder: '<db-alias>'` | the same placeholder, quoted, reached remote-run | as above |
| `--host needs a value (got '--expect-ip')` | a flag without its value | give the value |
| `sudo: a terminal is required to read the password` / `sudo: a password is required` | old behaviour: sudo needed a password and the session had no terminal | update; remote-run now detects this. Run it in a terminal and type the password at sudo's prompt, or give the login user passwordless sudo |
| `sudo on <host> needs the login user's password, and this session has no terminal` | the probe found a password-protected sudo and stdin is not a terminal | run it from Terminal/iTerm, not a script or pipe. Nothing was uploaded |
| `cannot ssh to <host>` | wrong key, user or host | `ssh -i ~/.ssh/<db-key> -o IdentitiesOnly=yes <user>@<db-public-ip> true`; pass `-i` |
| `ABORT: this is <hostname>, not the db server` | `--expect-ip` does not match the server | wrong host or wrong IP; nothing changed |
| `still <placeholders> in .env: SIWO_DB_...` | a server key in `.env` is still a template value | fill it in or comment it out, or pass `--no-config` |

Engines (on/off, drift after a manual `docker rm`, re-enable, purge): see
[users and privileges: turning engines on and off](../databases/users-and-privileges.md#turning-engines-on-and-off)
and the walkthrough in [rehearsals/2026-11-engines-off-live.md](../rehearsals/2026-11-engines-off-live.md).
