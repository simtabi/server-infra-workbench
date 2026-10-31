# `bin/workbench` — the command line

One entry point for everything in the repo. It only resolves paths and execs: shell tools keep their own
flags, platform commands run on the [PHP core](platform-api.md), and `py` runs the [Python package](python.md).

```bash
bin/workbench list                         # every tool and where it lives
bin/workbench help                         # this summary;  bin/workbench help do|cf|ploi|gcp  for one area
```

Optional: put it on your `PATH` with `ln -s "$PWD/bin/workbench" ~/.local/bin/workbench`.

## Shell tools: `workbench <area> <tool>`

Runs `src/shell/<area>/<tool>.sh` with the remaining arguments, unchanged.

```bash
bin/workbench db remote-run --host db-01 --expect-ip 10.0.0.5 -- doctor
bin/workbench web check-db-reach 10.0.0.5
bin/workbench tunnels db-tunnel --help
```

Area and tool names must match `[a-z0-9-]+`, so nothing outside `shell/` can be reached.

## Platform APIs: `workbench do|cf|ploi|gcp`

Requires PHP 8.4+ and `composer install --working-dir=src/php` (the dispatcher says so if either is missing).

| Command | What it does |
|---|---|
| `workbench do droplets [--tag T]` | List droplets: id, name, status, region, size, private and public IPv4 |
| `workbench do droplet <id>` | One droplet |
| `workbench do snapshots [<droplet-id>]` | All droplet snapshots, or one droplet's |
| `workbench do snapshot <droplet-id> [--name N] [--wait] [--timeout S]` | **Write.** Snapshot a droplet (default name `workbench-<id>-<UTC time>`) |
| `workbench do snapshot-delete <snapshot-id>` | **Destructive.** Needs `--force` |
| `workbench do account` | Check the token (prints the account record) |
| `workbench cf zones` | List zones |
| `workbench cf dns list <zone> [--type T] [--name N]` | DNS records in a zone (name or id) |
| `workbench cf dns upsert <zone> <type> <name> <content> [--ttl 1] [--proxied] [--priority P] [--comment C]` | **Write.** Create, update, or report "no change". Short names expand (`db` → `db.example.com`); refuses when several records match |
| `workbench cf dns delete <zone> <record-id>` | **Destructive.** Needs `--force` |
| `workbench cf verify` | Check the token is active |
| `workbench ploi servers` / `server <id>` / `sites <server-id>` | Read servers and sites |
| `workbench ploi deploy <server-id> <site-id>` | **Write.** Run the site's deploy script |
| `workbench gcp instances [--zone Z]` | Instances, all zones unless `--zone` |
| `workbench gcp snapshots` / `firewalls` | Snapshots; firewall rules (`WORLD-OPEN` marks rules open to `0.0.0.0/0`) |
| `workbench gcp snapshot <zone> <disk> [--name N] [--wait]` | **Write.** Snapshot a persistent disk |
| `workbench credentials` | Where each credential comes from (`env`, `file`, `missing`); never prints values |
| `workbench version` | Library and PHP version |

GCP commands take `--project P` (else `GCP_PROJECT`, else the service-account key's project).
`digitalocean`, `cloudflare` and `gcloud` work as aliases of `do`, `cf` and `gcp`.

### Flags

| Flag | Effect |
|---|---|
| `--dry-run`, `-n` | Print the plan (method, path, payload) and send nothing. Still needs a token for commands that must read first (DNS upsert) |
| `--yes`, `-y` | Run a write without the prompt. Without it, a terminal asks you to type `yes`; with no terminal the command stops |
| `--force` | Also required for destructive commands, together with `--yes` (or the prompt) |
| `--json` | Machine-readable output on stdout (DTOs, plans and results as JSON) |
| `--verbose` | Log each request and retry to stderr, redacted |

Unknown options and malformed ids, zones, names, IPs or TTLs are rejected before anything is sent.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (including a dry run or a "no change" upsert) |
| 1 | The API or network call failed, or an action finished with an error |
| 2 | Usage or validation error |
| 3 | A write was not confirmed (no `--yes`, prompt declined, or `--force` missing) |
| 4 | Credentials missing or the credentials file is unsafe |

### Examples

```bash
bin/workbench credentials
bin/workbench do droplets --tag db --json | jq -r '.[] | "\(.name) \(.privateIpv4)"'
bin/workbench do snapshot 123456 --name db-pre-upgrade --dry-run      # see exactly what would be sent
bin/workbench do snapshot 123456 --name db-pre-upgrade --yes --wait   # take it and wait for completion
bin/workbench cf dns upsert example.com A db 203.0.113.10 --ttl 300 --dry-run
bin/workbench cf dns upsert example.com A db 203.0.113.10 --ttl 300 --yes
bin/workbench ploi deploy 42 1001 --yes
bin/workbench gcp firewalls --project my-project
```

In your own shell scripts, quote the area when it follows another word that bash treats as a keyword
(`bin/workbench 'do' droplets`), or use the `digitalocean` alias; shellcheck flags a bare `do` (SC1010).

Every write, dry runs included, is appended to the audit log (`~/.local/state/vps-server-workbench/audit.log`;
`VSW_AUDIT_LOG=off` to disable). See [platform-api.md](platform-api.md#audit-log).

## Python: `workbench py`

```bash
bin/workbench py ping 10.0.0.5 6432 --json
```

See [python.md](python.md).

## Checks

`make test` exercises the dispatcher offline: listing, shell routing, bad names, that no legacy `scripts/` or `tools/` path is back,
Python input validation, and (when PHP is available) a DigitalOcean dry run, refusal without `--yes`, and
the missing-credentials exit code.
