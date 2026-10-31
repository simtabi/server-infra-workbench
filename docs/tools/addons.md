# Add-ons tool

`src/shell/addons/addon.sh` (also `bin/workbench addons addon ...`) installs optional services next to the
app: Gotenberg for PDFs and one S3-compatible object store. The templates and the comparison are in
[stacks/addons](../../stacks/addons/README.md); the decision is [ADR 0007](../adr/0007-object-storage-selection.md).

## Commands

| Command | Does | Writes |
|---|---|---|
| `list` | add-ons, kind, default role, pinned image, installed role/bind | nothing |
| `plan <name> [--role R] [--bind IP] [--data-dir D]` | role, bind, ports, image, files, secrets to generate (names only), RAM check, diff against the installed settings | nothing |
| `install <name> [...] [--yes]` | plan, then you type the name (or pass `--yes`), then it generates credentials, renders the files, runs `compose up --wait`, creates the bucket and app key, and checks health | `/opt/vsw-addons/<name>/`, audit log |
| `status [name]` | `docker compose ps` per add-on | nothing |
| `doctor [name]` | see [checks](../../stacks/addons/README.md#doctor-checks); exits 1 on a problem | nothing |
| `laravel-env <name> [--out FILE]` | writes the Laravel keys to FILE (600, backs up an existing one); prints key names only | FILE |
| `garage-node-id` | this node's Garage `<id>@<addr>` for `GARAGE_PEERS` on the next node ([cluster](../../stacks/addons/garage/README.md#three-node-cluster)) | nothing |
| `remove <name> [--delete-data] [--yes]` | `compose down`; keeps files and credentials in `.removed-<name>-<ts>/` unless `--delete-data` (you type `delete <name> data`, or pass `--force`) | `/opt/vsw-addons` |

Flags: `--accept-experimental` (RustFS), `--force`, `-h`. Exit codes: 0 ok, 1 refused or failed, 2 usage.

## Safety rules

- It runs as root on the node. One run at a time (`/opt/vsw-addons/.lock`).
- **Binding**: `0.0.0.0`, `::` and public addresses are refused. The `web` role uses `127.0.0.1`; `db` and
  `dedicated` use the eth1 VPC address. Consoles and admin APIs bind `127.0.0.1` only.
- **Credentials** are generated once with `openssl rand` into `secrets.env` (600). They are never echoed,
  never written to the audit log, and never rotated silently. Re-running `install` reuses them.
- **Least privilege**: the app key can read and write one bucket. It cannot create buckets, delete buckets
  or change bucket settings.
- **Pinned images only**; `doctor` flags `:latest` or a container running a different image.
- **Experimental add-ons** need `--accept-experimental` and are refused when `ADDON_ENV` is in
  `PROTECTED_ENVS`. RustFS default credentials are refused.
- A changed `garage.toml` or `s3.json` recreates the container (hash label). A failed first install removes
  its containers and keeps the files.
- `/etc/vsw-addons.conf` is sourced, so it must be owned by root and not world-writable.

## Files on the node

| Path | Mode | Holds |
|---|---|---|
| `/etc/vsw-addons.conf` | 600 | optional settings, no secrets ([example](../../config/addons.conf.example)) |
| `/opt/vsw-addons/addon.sh`, `stacks/` | 700 | installed copy of the tool and templates |
| `/opt/vsw-addons/<name>/docker-compose.yml` | 600 | the pinned template |
| `/opt/vsw-addons/<name>/stack.env` | 600 | non-secret settings recorded by install |
| `/opt/vsw-addons/<name>/secrets.env` | 600 | generated credentials |
| `/opt/vsw-addons/garage/garage.toml`, `seaweedfs/s3.json` | 600 | configs that include secrets |
| `/var/log/vsw-addons.log` | 600 | audit trail without secrets |

## Tests

- `tests/shell/smoke-addons.sh` (offline, in `make test`): gates, refusals, binding rules, pins, compose
  hygiene, secret file handling.
- `tests/shell/addons-it.sh` (Docker, in `make it`, about 1 minute): Gotenberg (PDF, SSRF guard, basic auth),
  Garage (layout, bucket, least-privilege key, idempotent re-install, remove), SeaweedFS (bucket-scoped
  identity, admin login), and a scan that no secret reaches any output.
- `tests/shell/addons-it.sh` also installs RustFS: the experimental gate, the bucket made with the generated
  root key, signed put/get, anonymous denied, the console on 127.0.0.1, and `laravel-env` without the root key.
- `tests/shell/garage-cluster-it.sh` (Docker, in `make it`, about 1 minute): three Garage nodes in **host
  networking** mode (S3, RPC and admin on 127.0.0.1 only, no published ports), `GARAGE_REPLICATION=3`, joins
  with `GARAGE_PEERS` and a copied `secrets.env`, layout applied by the third node, a cross-node read, one node
  down (quorum 2 of 3), catch-up, doctor, and the replication-change refusal.
