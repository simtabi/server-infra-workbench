# Servers in different regions

DigitalOcean VPC networks are **per region**: a droplet in `nyc1` and one in `ams3` are in different VPCs, and
their private (`eth1`) addresses don't route to each other unless you connect the VPCs. The DB manager binds
every database port to the private IP only, so a web server in another region simply gets "connection timed
out". This page lists the options from best to last resort, and the workbench commands for each.

## Contents

- [Find out where your servers are](#find-out-where-your-servers-are)
- [The options](#the-options)
- [1. Same region (recommended)](#1-same-region-recommended)
- [2. DO VPC peering](#2-do-vpc-peering)
- [3. WireGuard tunnel](#3-wireguard-tunnel)
- [4. TLS over the public IP with an allowlist](#4-tls-over-the-public-ip-with-an-allowlist)
- [5. Managed database with trusted sources](#5-managed-database-with-trusted-sources)
- [Checks the tools run](#checks-the-tools-run)

## Find out where your servers are

```sh
bin/workbench do droplets                         # REGION and PRIVATE IP columns
bin/workbench web check-db-reach --remote <web> --db-region <db-region> <db-private-ip> 6432 5432
sudo /root/docker-db-server-manager.sh doctor     # "Network: region and VPC", with PEER_REGIONS set
```

On a droplet, `curl -s http://169.254.169.254/metadata/v1/region` prints its region.

## The options

| # | Option | Encryption | Extra latency | Cost | Effort | Use it when |
|---|---|---|---|---|---|---|
| 1 | Same region and VPC | not needed inside the VPC (turn on `TLS_MODE=require` anyway for prd) | none | free | move one droplet (snapshot, recreate) | always, if you can |
| 2 | DO VPC peering | DO's private backbone (add TLS for prd) | the distance between regions | $0.01/GiB between regions (DO pricing) | a few clicks, plus a route refresh on droplets created before 2 Oct 2024 | the servers must stay in two regions |
| 3 | WireGuard tunnel | yes (WireGuard) | the distance + a little | public bandwidth counts against the droplets' transfer | `workbench net wireguard setup` | peering is unavailable (BLR1), or the other side isn't on DO |
| 4 | TLS over the public IP + allowlist | yes (TLS) | the distance | public bandwidth | config + a cloud firewall | short-term, two hosts, nothing else possible |
| 5 | Managed DB, trusted sources | yes (TLS, `verify-full`) | the distance | the managed DB price | create the DB, add trusted sources | prd on managed Postgres anyway ([ADR 0008](adr/0008-database-topology.md)) |

Latency is physics: every query pays the round trip between regions (a few ms inside a coast, 70-90 ms across
the Atlantic, estimates). Laravel pages that run dozens of queries feel it. Keep the app and its database in
one region; put only replicas, backups or a DR copy elsewhere.

## 1. Same region (recommended)

Move the droplet that's in the wrong region: snapshot it, transfer the snapshot to the right region, create a
droplet from it in the right VPC, then switch DNS or the app's `DB_HOST`. Plan downtime for the DB.

```sh
bin/workbench do snapshot <droplet-id> --name move-$(date +%Y%m%d) --wait --dry-run   # then without --dry-run
```

## 2. DO VPC peering

Create the peering in the control panel (Networking -> VPC -> Peerings) or the API. Droplets created before
2 October 2024 need their routes refreshed (DO: "How to Update Droplet Routes to Enable VPC Peering"). Peering
isn't available between datacenters in BLR1, and two VPCs can't peer if one's range overlaps a range DO
reserves in the other region.

Then, in the DB manager config:

```sh
VPC_PEERING=1
PEER_REGIONS=nyc1                 # the app servers' region(s)
ALLOW_prd=10.10.0.5/32            # the app server's private IP in its own VPC (or widen VPC_CIDR)
```

`VPC_CIDR` must contain the other VPC's range (the default `10.0.0.0/8` does). Run `upgrade --dry-run`,
`upgrade`, then `doctor`.

## 3. WireGuard tunnel

```sh
bin/workbench net wireguard setup --host <db-ssh> --peer <web-ssh> --dry-run   # read the plan
bin/workbench net wireguard setup --host <db-ssh> --peer <web-ssh>             # type yes
```

What it does (details in [Networking tools](tools/net.md)):

- Each server installs `wireguard-tools` and makes its own key in `/etc/wireguard/wg0.key` (600). Private keys
  never leave the server and are never printed; public keys show only as fingerprints.
- `wg0` gets `10.200.0.1` (DB) and `10.200.0.2` (web); each side lists only the other as peer.
- ufw opens UDP 51820 from the other server's public IP only, and on the DB, the DB ports on `wg0` from
  `10.200.0.2` only. On a Ploi server it prints the rule to add in Ploi's Network tab instead.
- On the DB, Docker starts after the tunnel, because the DB ports are published on `10.200.0.1`.

Then:

1. DO cloud firewall: allow UDP 51820 from the other server's public IP, on both droplets.
2. DB manager config: `EXTRA_BIND_IPS=10.200.0.1` and `PEER_REGIONS=<web region>`; `upgrade --dry-run`,
   `upgrade`.
3. The app's `.env`: `DB_HOST=10.200.0.1` (`bin/workbench env check`).
4. `bin/workbench net wireguard status --host <web> --ping 10.200.0.1` and `check-db-reach`.

The `cross-region-wireguard` profile ([profiles](reference/profiles.md)) sets this up through `configure`.

## 4. TLS over the public IP with an allowlist

Only when nothing above is possible. Docker-published ports **bypass ufw**, so the allowlist must be a DO
cloud firewall, not ufw.

```sh
# DB manager config
TLS_MODE=require                  # the manager refuses a public bind without it
ALLOW_PUBLIC_BIND=1               # says the public bind is on purpose
EXTRA_BIND_IPS=<db public ip>
ALLOW_prd=<web public ip>/32      # pg_hba: only that host may log in as prd roles
# cloud firewall: DB ports from the web server's public IP only
bin/workbench do firewall-apply db --vpc <web-public-ip>/32 --ports 6432 --droplet <db-id> --dry-run
```

The app connects with `sslmode=verify-full` and the DB's CA (`/opt/db/tls/ca.crt`, copied to the web
server). `doctor` warns about every public bind until you remove it.

## 5. Managed database with trusted sources

DigitalOcean Managed Postgres in the web server's region (or reachable over peering), with the web droplets
as trusted sources and `sslmode=verify-full`. The manager prints the role SQL for it with `env-sql prd`
([database environments](database-environments.md)).

## Checks the tools run

| Tool | Check |
|---|---|
| `doctor` (DB) | this droplet's region from DO metadata; each `PEER_REGIONS` entry: same region ok, `VPC_PEERING=1` ok, a `wg0` bind ok, public TLS bind warn, otherwise PROBLEM with the fixes; `PRIVATE_IP` inside `VPC_CIDR`; a warning per public bind |
| `validate_config` (DB) | `PRIVATE_IP` must be private; a public `EXTRA_BIND_IPS` entry needs `ALLOW_PUBLIC_BIND=1` and `TLS_MODE=require` |
| `check-db-reach` (web) | its own region and VPC from metadata; warns when `--db-region` differs, or the DB's private IP is outside its VPC, or the DB address is public |
| `configure` | `REGION`/`PEER_REGION`, WireGuard needs a different peer region, IPs inside the VPC |

See [ADR 0011](adr/0011-cross-region-connectivity.md) for why the order is what it is.
