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
| 8 | Inventory drift | `bin/workbench server inventory --install-cron --yes` on each host | daily files in `/var/lib/vps-server-workbench/inventory` | shows what changed when something breaks |
