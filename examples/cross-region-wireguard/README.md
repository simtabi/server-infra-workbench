# Example: web and DB in different regions over WireGuard

Made up: web in `nyc3`, DB in `ams3`. DigitalOcean VPCs are per region, so the DB traffic goes through a
WireGuard tunnel (`10.200.0.0/24`: DB `10.200.0.1`, web `10.200.0.2`). TLS stays on inside the tunnel.

**Why:** moving a DB across regions is slow and risky; a tunnel lets the web tier move first. Expect extra
latency per query (a few ms to tens of ms, depending on the pair), so batch queries. Options and trade-offs:
[cross-region](../../docs/cross-region.md#3-wireguard-tunnel).

```bash
examples/run.sh cross-region-wireguard      # validate (offline)
bin/workbench net wireguard setup --host <db-alias> --peer <web-alias> --dry-run   # plan, writes nothing
bin/workbench net wireguard setup --host <db-alias> --peer <web-alias> --yes       # keys generated on each host
```

Private keys are generated on each server (`wg genkey`, 600) and never leave it or reach the output.
Tested end to end in containers: `tests/shell/wg-it.sh` (two hosts, real ssh, kernel WireGuard, ufw).

Checklist:

- [ ] DO cloud firewall: UDP 51820 from the peer's public IP only
- [ ] DB manager: `EXTRA_BIND_IPS=10.200.0.1`, then `upgrade --dry-run`, then `upgrade`
- [ ] App `.env`: `DB_HOST=10.200.0.1`; check with `bin/workbench web check-db-reach --remote <web-alias> 10.200.0.1 6432`
