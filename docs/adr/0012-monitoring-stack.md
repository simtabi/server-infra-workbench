# 0012. Monitoring: configurable self-hosted stacks, loopback UIs, textfile metrics from the DB manager

- Status: Accepted
- Date: 2026-10-31

## Context

DigitalOcean's agent covers CPU, memory and disk. It can't see failed backups, stale restore tests,
PgBouncer saturation or TLS expiry. Clients range from one 2 GB droplet to a load-balanced pair. No single
tool fits every size: Prometheus + Grafana is the most capable option but costs about 700 MB, while Beszel
costs under 100 MB but has no rule engine. The database must never be OOM-killed because of monitoring, and
no dashboard may face the internet by accident (Docker-published ports bypass ufw).

## Decision

- One tool, `monitor.sh`, with four optional stacks (`beszel`, `kuma`, `netdata`, `prometheus`) chosen by
  `MONITOR_STACKS`, and a role per node (`hub`, `agent`, `both`). Profiles pick light defaults
  (`beszel`, `beszel,kuma`); `prometheus` is opt-in.
- UIs bind loopback only and are reached by SSH tunnel. A public Caddy front needs `MONITOR_PUBLIC=1` plus
  basic auth, and is refused on Ploi servers.
- Agents bind the private or WireGuard IP with host networking. `0.0.0.0` and public IPs are refused.
- A RAM gate (exit 3) blocks heavy stacks next to a DB on 2 GB or less unless `MONITOR_ALLOW_TIGHT=1`.
- DB exporters log in as a dedicated `vsw_monitor` role (`pg_monitor`, connection limit 5, `postgres`
  database only), created by the DB manager's `monitor-user`. Its password lives in a 600 file.
- The DB manager publishes "last success" facts as a node-exporter textfile (`vsw_db.prom`). The alert rules
  are built on those facts.
- Secrets are generated per unit into `secrets.env` (600) and passed with `--env-file`. They are never
  printed and never rotated silently.

## Consequences

- Small servers get useful monitoring for about 100 MB; bigger ones can grow into Prometheus without a
  different tool.
- Backup and restore-test staleness alert from the server itself, not only by email from cron.
- Reaching the UIs takes an SSH tunnel. That is a deliberate trade of convenience for exposure.
- Host networking can't be tested on Docker Desktop. The IT suite runs bridge mode, and the doctor checks
  the real listeners on servers.
- Rejected: a SaaS (cost, data leaving the server), Zabbix (too heavy for 2 GB nodes), and exposing Grafana
  behind nginx by default (a public login page for every client).
