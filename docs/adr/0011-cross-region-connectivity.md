# 0011. Cross-region connectivity: same region first, then peering, then WireGuard

- Status: Accepted
- Date: 2026-10-31

## Context

DigitalOcean VPCs are regional. The DB manager publishes database ports on the private IP only, which is the
main reason the databases aren't on the internet (Docker-published ports bypass ufw). A web server in another
region can't reach that address. We needed a supported path that keeps the "never on a public interface
without a reason" rule. The options: move a server, DO VPC peering (cross-region since 2024, billed per GiB),
a WireGuard tunnel, TLS over the public IP with a cloud-firewall allowlist, or a managed database with trusted
sources.

## Decision

- Recommend **one region** for the app and its database. Latency between regions is paid on every query.
- If two regions are unavoidable: **VPC peering** first (no software to run), then **WireGuard**
  (`siwo net wireguard setup`, keys made on each server and never printed, ufw open to the peer only).
- A **public bind** is allowed only as an explicit choice: `ALLOW_PUBLIC_BIND=1` plus `TLS_MODE=require`,
  with the allowlist in a DO cloud firewall; `doctor` warns for as long as it exists.
- The manager gets `EXTRA_BIND_IPS` (the tunnel or public address), `PEER_REGIONS` and `VPC_PEERING` so
  `doctor` can tell a working setup from a broken one.

## Consequences

- The default stays private-only; nothing changes for single-region servers.
- WireGuard adds a service per server to monitor (`wireguard status`) and UDP 51820 in two firewalls.
- `doctor` reports PROBLEM for a region mismatch it can't explain, so a mistaken move is caught early.
- Public binds remain possible but noisy by design.
