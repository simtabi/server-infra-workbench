# Example: monitoring (Beszel + Uptime Kuma, Prometheus + Grafana as the upgrade)

Made up: staging with the hub (UIs, storage) on the web node and agents on every node. UIs bind
`127.0.0.1` (use an SSH tunnel); agents bind the private IP.

**Why this default:** Beszel + Kuma need about 300 MB; Prometheus + Grafana about 700 MB, which on a 2 GB DB
droplet is the OOM killer's next target. `monitor plan` gates RAM (exit 3). See
[ADR 0012](../../docs/adr/0012-monitoring-stack.md) and [the monitor tool](../../docs/tools/monitor.md).

```bash
examples/run.sh monitoring                  # configure checks + `monitor plan` for the hub
bin/siwo monitor plan --role hub --stacks prometheus    # the upgrade; refused on a small host
```

Admin passwords (Beszel, Grafana) are generated into `<unit>/secrets.env` (600) at install and never printed.

Checklist:

- [ ] Every node has an agent; the hub lists them (`bin/siwo monitor doctor`)
- [ ] One uptime check per public URL (`MONITOR_PROBE_URLS`)
- [ ] Alert email or webhook tested once
