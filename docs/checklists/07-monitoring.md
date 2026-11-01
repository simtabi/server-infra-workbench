# 07. Monitoring and alerts

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | DO metrics agent | `server init` installs it (`do-agent`) | the droplet's Graphs tab shows memory | memory and disk alerts need the agent |
| 2 | CPU, memory, disk alerts | `bin/workbench do alerts standard --email <you> --tag db --dry-run`, then `--yes` (repeat for `web`) | `bin/workbench do alerts` lists cpu>85, memory>90, disk>85 | hear about it before users do |
| 3 | Uptime check on the app | `bin/workbench do uptime check-create <name> https://<domain>/up --dry-run`, then `--yes` | `bin/workbench do uptime state <check-id>` UP | the user-facing signal |
| 4 | Down and TLS-expiry alerts | `bin/workbench do uptime alert-create <check-id> down --email <you>`; again with `ssl_expiry` | `do uptime alerts <check-id>` | an expired certificate is an outage too |
| 5 | DB doctor alerts | `ALERT_EMAIL` or `HEALTHCHECK_URL` in the config; `M cron-install` | `M doctor --alert` once; the alert arrives | catches exposure, privilege drift, stale backups |
| 6 | Backup check-in | `HEALTHCHECK_URL` (see [06](06-backups-and-dr.md)) | a ping per backup | a missed backup gets noticed |
| 7 | Tunnel health (cross-region only) | `bin/workbench net wireguard status --host <web> --ping <db-tunnel-ip>` | handshake under 3 minutes | a dead tunnel looks like a dead DB |
| 8 | Inventory drift | `bin/workbench server inventory --install-cron --yes` on each host | daily files in `/var/lib/server-infra-workbench/inventory` | shows what changed when something breaks |
| 9 | Monitoring login on the DB | `M monitor-user` | `/etc/vsw-monitor/pg-monitor.pass` is 600; `M doctor` clean | exporters get `pg_monitor` only, never the app or admin login |
| 10 | Pick stacks per node | `MONITOR_STACKS` and `MONITOR_ROLE` in `/etc/vsw-monitor.conf` ([example](../../config/monitor.conf.example)), then `bin/workbench monitor plan` | the plan shows binds, RAM estimate, firewall rule; exit 3 = RAM gate | heavy stacks next to a 2 GB database get OOM-killed first ([ADR 0012](../adr/0012-monitoring-stack.md)) |
| 11 | Install agents, then the hub | `bin/workbench monitor install` on the DB node (agent), then on the hub node | `monitor doctor` reports 0 problems; agents listen on the private IP only | agents first, so the hub finds its targets at once |
| 12 | Register nodes and probes | `monitor beszel-key`, `monitor beszel-register --name db --host <db-private-ip>`; `MONITOR_PROBE_URLS` + `monitor targets` | Beszel shows both systems; Prometheus targets all `up` | an unregistered node is silently unmonitored |
| 13 | Reach the UIs | `monitor tunnel --host <ssh-alias>`, then open `http://127.0.0.1:<port>` | Grafana asks for a login (anonymous gets 401) | UIs are loopback only; the tunnel is the access control |
| 14 | Backup metrics | nothing to do: `backup`, `offsite`, `restore-test` refresh `vsw_db.prom` when `METRICS_TEXTFILE_DIR` exists (`M metrics` by hand) | `VswBackupStale` and friends are loaded (`monitor status`) | the alert fires from the server even if cron mail is lost |

Lessons learned: [monitoring](../tools/monitor.md#lessons-learned).

