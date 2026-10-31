# Networking tools

`src/shell/net/wireguard.sh` (`bin/workbench net wireguard ...`): an encrypted WireGuard tunnel between two
servers, for a web server and a DB server in different regions. Why and when: [Servers in different
regions](../cross-region.md).

## Commands

| Command | What it does |
|---|---|
| `setup --host <db> --peer <web> [--dry-run\|--yes]` | reads both servers (public IP, region, Ploi, existing config), prints the plan, asks, then makes keys, writes configs, opens ufw for the peer only, starts `wg-quick@wg0`, checks the handshake and prints the next steps |
| `status --host <ssh> [--ping IP]` | handshake age, bytes in/out, optional ping through the tunnel; never shows keys |
| `remove --host <ssh> [--yes]` | stops and disables the tunnel, backs up the config, removes the Docker ordering drop-in; keeps the key and leaves ufw rules for you to review |

Options: `--host-ip`/`--peer-ip` (default `10.200.0.1`/`10.200.0.2`, same /24), `--host-endpoint`/
`--peer-endpoint` (public IPs, detected by default), `--port` (51820), `--db-ports` (5432,6432; opened on `wg0`
from the peer's tunnel IP on the DB side only), `--iface` (wg0), `--ploi-ufw` (also write ufw rules on a Ploi
server; by default the rule is printed for Ploi's Network tab).

## Safety

- **Keys.** Each server runs `wg genkey` into `/etc/wireguard/wg0.key` (umask 077, 600). `wg0.conf` loads it with
  `PostUp = wg set %i private-key ...`, so the private key isn't in the config either. Only public keys cross
  the workstation, in memory, shown as 12-character fingerprints. Re-running keeps existing keys.
- **Firewall.** UDP 51820 from the other server's public IP only; DB ports on `wg0` from the peer tunnel IP
  only. Rules are added once (re-runs don't duplicate them). Add the same UDP rule in the DO cloud firewall.
- **Ordering.** On the DB side, `docker.service` gets `After=wg-quick@wg0.service`, so Docker can publish the
  DB ports on the tunnel IP after a reboot.
- **Plan, confirm, audit, lock.** As every server tool: nothing changes without `--yes` or typed `yes`; each
  server logs to `/var/log/vps-server-workbench/audit.log` (fingerprints only).

## After setup

1. DB manager config: `EXTRA_BIND_IPS=10.200.0.1`, `PEER_REGIONS=<web region>`, then `upgrade --dry-run` and
   `upgrade`. `doctor` then reports "reached over WireGuard".
2. App `.env`: `DB_HOST=10.200.0.1`.
3. `bin/workbench web check-db-reach --remote <web> 10.200.0.1 6432 5432`.

## Testing

`tests/shell/smoke-net.sh` (in `make test`) runs both sides locally against fake roots with stub `wg`, `ufw`,
`systemctl`, `ip` and `curl`: plan without changes, confirmation, modes, no private key in output, configs or
logs, key exchange, peer-only rules, Ploi handling, idempotent re-runs, validation and removal. 
`tests/shell/wg-it.sh` (in `make it`) builds a real tunnel between two Ubuntu 24.04 containers: real ssh
(a throwaway test key, never printed), kernel WireGuard with only `--cap-add NET_ADMIN` (no `--privileged`),
real ufw. It checks the dry run, handshake and ping both ways, that no private key reaches output, configs or
the audit log, 600 modes, peer-only ufw rules, that PgBouncer's port answers through the tunnel and not
outside it, idempotent re-runs, `status` and `remove`. If the Docker kernel cannot create a `wireguard` link
it prints SKIP and exits 0 (set `WG_IT_REQUIRE=1` to make that a failure, e.g. in CI). The containers have no
systemd, so a small stub maps `systemctl ... wg-quick@wg0` to `wg-quick`.
