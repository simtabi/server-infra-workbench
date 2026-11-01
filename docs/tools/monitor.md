# Monitoring tool

`src/shell/monitor/monitor.sh` (also `bin/siwo monitor ...`) installs self-hosted monitoring on one node.
You pick the stacks with `MONITOR_STACKS` and the node's side with `MONITOR_ROLE`. The configurator writes
the settings for you (`MONITOR_*` keys in [profiles](../reference/profiles.md)). The decision record is
[ADR 0012](../adr/0012-monitoring-stack.md); the rollout steps are in [checklist 07](../checklists/07-monitoring.md).

**Why it exists:** DigitalOcean's graphs and alerts cover CPU, memory and disk. They don't tell you that last
night's backup failed, that PgBouncer is out of connections, or that the TLS certificate expires next week.
This tool closes that gap without a SaaS bill and without exposing a dashboard to the internet.

## Stacks

| Stack | Hub side (UI + storage) | Agent side (every monitored node) | RAM (estimate) | Use it for |
|---|---|---|---|---|
| `beszel` | Beszel hub | `beszel-agent` | 64 + 32 MB | host and container CPU, memory, disk, network; the lightest useful default |
| `kuma` | Uptime Kuma | (none) | 192 MB | HTTP, TCP and keyword checks with notifications; status pages |
| `netdata` | Netdata (on every node) | Netdata | 256 MB per node | per-second troubleshooting; **heavy** |
| `prometheus` | Prometheus, Alertmanager, Grafana, blackbox exporter | node-exporter, cAdvisor, postgres- and pgbouncer-exporter | 600 + 120 MB | alert rules, the DB manager's backup metrics, dashboards; **heavy** |

`none` turns monitoring off. Profiles: `staging` uses `beszel`, `production-single` and `production-ha` use
`beszel,kuma`. Add `prometheus` once a node has the RAM (a 4 GB web node or a dedicated hub).

**Roles:** `hub` installs the hub side, `agent` the agent side, `both` does both (single-node setups and the
hub node itself). The configurator puts `both` on the hub node (`MONITOR_HUB=web|db|dedicated`) and `agent`
everywhere else.

## Commands

| Command | Does | Writes |
|---|---|---|
| `list` | units, stack, side, RAM estimate, pinned images, installed? | nothing |
| `plan [--role R] [--stacks a,b]` | units, binds, images, targets, alert receivers, firewall hint, RAM gate | nothing |
| `install [--role R] [--stacks a,b] [--yes]` | plan, confirm (type `monitor`), secrets, `compose up --wait`, Beszel self-registration | `/opt/vsw-monitor/<unit>/`, audit log |
| `targets` | re-renders Prometheus targets and `alertmanager.yml` from the conf, reloads (no restart) | prometheus unit |
| `beszel-register --name N --host H [--port P]` | adds a node to the hub through its API (idempotent) | hub database |
| `beszel-key --out FILE` | the hub's **public** key for agents on other nodes (644) | FILE |
| `tunnel [--host SSH]` | the `ssh -N -L ...` line for every installed UI | nothing |
| `caddy --domain D` | a Caddy site block with basic auth (needs `MONITOR_PUBLIC=1`; refused on Ploi servers) | `caddy/` |
| `status` / `doctor` | containers; perms, pins, health, binds, targets, rules, Grafana auth (doctor exits 1 on a problem) | nothing |
| `remove <unit> [--delete-data] [--yes]` | stops a unit; files kept in `.removed-<unit>-<ts>/` unless `--delete-data` | `/opt/vsw-monitor` |

Exit codes: 0 ok, 1 refused or failed, 2 configuration error, 3 RAM gate.

## Safety rules (and why)

- **UIs bind loopback only** (`MONITOR_BIND` must be `127.x`). You reach them through `monitor.sh tunnel`.
  WHY: Docker-published ports bypass ufw, so "I'll firewall it later" is not a control.
- **Agents bind the private or WireGuard IP** (`MONITOR_AGENT_BIND`), never `0.0.0.0` or a public address.
  Host networking is the default for agents, so they see the real host; `bridge` exists for tests and laptops.
- **RAM gate:** heavy units (`netdata`, `prometheus`) next to a database on a node with 2 GB or less exit
  with code 3. So does a plan that needs more than the available memory. `MONITOR_ALLOW_TIGHT=1` (or
  `--allow-tight`) overrides it with a warning. WHY: an OOM-killed Postgres is a worse outage than a missing graph.
- **Secrets** are generated with `openssl rand` into `<unit>/secrets.env` (600). Compose reads them through
  `--env-file`. They are never printed, logged or rotated silently. Alertmanager's webhook URL and SMTP
  password are copied into `am-secrets/` (400, owned by the alertmanager user), and `alertmanager.yml` only
  references them by file name.
- **DB access** for the exporters is the `vsw_monitor` role from the DB manager's `monitor-user`. It has
  `pg_monitor`, `CONNECTION LIMIT 5`, and can only connect to the `postgres` database. It can't read
  application data.
- **Pinned images only**; `plan` and `doctor` refuse `:latest`.
- `/etc/vsw-monitor.conf` is sourced, so when root runs the tool it must be owned by root and not world-writable.
- One run at a time (`/opt/vsw-monitor/.lock`). Every install, removal and registration goes to
  `/var/log/vsw-monitor.log`.

## What Prometheus watches

The rules live in [`stacks/monitor/prometheus/rules/vsw.yml`](../../stacks/monitor/prometheus/rules/vsw.yml):
node down, disk over 85%/95%, memory, load, container restarts, Postgres down, connections over 80%,
PgBouncer waiting clients, probe failures, TLS expiry, backup older than 26 h, off-site copy older than 26 h,
restore test older than 8 days, DB doctor problems, and reboot required.

The backup, restore-test and TLS facts come from the DB manager. After each backup, restore test, off-site
copy and doctor run, the manager writes `vsw_db.prom` into `METRICS_TEXTFILE_DIR`, and node-exporter serves
it. WHY a textfile: only the manager knows when a backup *succeeded*. A file needs no extra daemon and
survives exporter restarts. `bin/siwo db ... metrics` rewrites it by hand.

## Files on the node

| Path | Mode | Holds |
|---|---|---|
| `/etc/vsw-monitor.conf` | 600 | settings, no secrets ([example](../../config/monitor.conf.example)) |
| `/opt/vsw-monitor/monitor.sh`, `stacks/` | 700 | installed copy of the tool and templates |
| `/opt/vsw-monitor/<unit>/stack.env` | 600 | non-secret settings recorded by install |
| `/opt/vsw-monitor/<unit>/secrets.env` | 600 | generated credentials |
| `/opt/vsw-monitor/prometheus/targets/*.json` | 644 | file_sd targets (`targets` rewrites them) |
| `/etc/vsw-monitor/pg-monitor.pass` | 600 | `vsw_monitor` password, written by the DB manager's `monitor-user` |
| `/var/lib/vsw-monitor/textfile/vsw_db.prom` | 644 | the manager's metrics |
| `/var/log/vsw-monitor.log` | 600 | audit trail without secrets |

## Typical rollout (two nodes, hub on web)

```bash
# DB node, as root: role + password file for the exporters, then the agent side
/root/docker-db-server-manager.sh monitor-user
MONITOR_CONF=/etc/vsw-monitor.conf monitor.sh plan     # role=agent; prints the firewall rule for the hub
monitor.sh install --yes
# web node (hub): UIs + collectors, then register the DB node's Beszel agent
monitor.sh install --yes
monitor.sh beszel-key --out /root/beszel-hub.pub        # copy to the DB node, set MONITOR_BESZEL_KEY_FILE there
monitor.sh beszel-register --name db --host 10.10.0.5
monitor.sh tunnel --host deploy@web-1                  # run the printed ssh line on your laptop
```

`bin/siwo configure` prints these steps per node, hub first, with the right file names.

## `siwo status`

`src/shell/server/status.sh` (`bin/siwo status`) is the one-screen answer to "is anything wrong right
now?": load, RAM, disk, containers (unhealthy ones named), reboot needed, last backup, monitor stacks, and
optional health URLs. It is read-only and takes no locks, so it's safe on prd at any time. `--json` is for
scripts, `--host H` runs it over ssh. It exits 1 when something needs a look (`STATUS_DISK_WARN`,
`STATUS_BACKUP_MAX_H`).

## Tests

- `tests/shell/smoke-monitor.sh` (offline, `make test`): validation, refusals, plans per role, RAM gate,
  pins, rendered targets / Alertmanager / stack.env, the configurator's conf passing `plan`, and `status.sh`.
- `tests/shell/monitor-it.sh` (Docker, `make it`, about 4 minutes): the manager plus `monitor-user`, then
  Beszel, Kuma, Prometheus and the exporters in bridge mode. It checks health, loopback binds, 600 secrets,
  no secret in output, Prometheus targets incl. the DB exporters, textfile metrics, rules, Grafana auth and
  provisioning, Beszel registration, a probe added by `targets`, idempotent re-install and remove.
- `make compose-check` renders every monitor compose file (incl. host networking) and runs `promtool check rules`.
- Not container-tested: host networking (Docker Desktop cannot), Netdata, email delivery, a two-node hub/agent pair.

## Lessons learned

- Docker Desktop and OrbStack proxy published ports, so a bind test passes there that would fail on a
  real host. The doctor checks the real host listeners with `ss` when host networking is used.
- `promtool` refuses metrics without `# HELP`; every gauge the manager writes has HELP and TYPE.
- Beszel's agent needs the hub's public key before it starts. Installing the hub first and reading the key
  through its API removes a manual copy-paste on single-node setups.
