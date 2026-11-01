# Garage add-on

Lightweight S3-compatible object storage from Deuxfleurs. It is the recommended self-hosted store here.

- Image `dxflrs/garage:v2.5.0`. It uses **host networking**, as Garage recommends. `garage.toml` binds S3
  (3900) and RPC (3901) to `ADDON_BIND` and the admin API (3903) to `127.0.0.1`. Set `ADDON_NETWORK=bridge`
  for Docker Desktop (that is what the tests use).
- Generated: `rpc_secret`, admin and metrics tokens, and the app key (`GK` + 24 hex). They are stored in
  `secrets.env` and `garage.toml`, both chmod 600.
- Install also sets up the layout (`layout assign -z $GARAGE_ZONE -c $GARAGE_CAPACITY`, then
  `layout apply`), the bucket `STORAGE_BUCKET`, and the key `vsw-app-<bucket>` with `--read --write` but no
  `--owner`. All of these steps are idempotent.
- Region `garage`, path-style URLs: `AWS_USE_PATH_STYLE_ENDPOINT=true`.
- Single node by default (`GARAGE_REPLICATION=1`). For redundancy build three nodes in three zones with
  `GARAGE_REPLICATION=3` from the start: Garage cannot change `replication_factor` on a live cluster, so
  `plan` refuses a change on an installed node.

## Three-node cluster

Why this order: every node must share `rpc_secret` (and the app key, so any node serves the same
credentials), and a replication-3 layout can only be applied once three zones have a role. Each install
stages its own role; the install that brings the cluster to three nodes applies the layout and creates the
bucket and key. `tests/shell/garage-cluster-it.sh` runs exactly this sequence.

| Step | On | Command | Verify |
|---|---|---|---|
| 1 | node A | `/etc/vsw-addons.conf`: `ADDON_NETWORK=host`, `GARAGE_REPLICATION=3`, `GARAGE_ZONE=dc1`; `addon.sh install garage --role dedicated` | output says `layout staged` |
| 2 | node A | `addon.sh garage-node-id` | `<64 hex>@<VPC IP>:3901` (an id, not a secret) |
| 3 | node B, C | copy `/opt/vsw-addons/garage/secrets.env` from A over ssh into the same path, `chmod 600` (`install -d -m 700 /opt/vsw-addons/garage` first) | `plan` no longer says "copy secrets.env" |
| 4 | node B | conf as A with `GARAGE_ZONE=dc2`, `GARAGE_PEERS=<A id>`; `install garage` | `layout staged` |
| 5 | node C | `GARAGE_ZONE=dc3`, `GARAGE_PEERS=<A id>,<B id>`; `install garage` | `layout apply version 1`, `bucket`, `app key` |
| 6 | any | `addon.sh doctor garage` | `layout applied`, `healthy nodes: 3 (replication 3)`; with one node down a warning `2 of 3` (still writable), below 2 a failure |

- Open 3901 between the nodes on the VPC only (`ufw allow from <VPC CIDR> to any port 3901 proto tcp`).
  RPC is authenticated with `rpc_secret`, but it should not face the internet.
- With replication 3, reads and writes need 2 of 3 nodes (the test stops one node and keeps working).
- Bridge mode is single-node only: peers can't reach RPC inside the container, so `GARAGE_REPLICATION>1`
  with `ADDON_NETWORK=bridge` is refused.

Note: the app secret is passed to `garage key import` inside the container, so it is briefly visible to root
in the process list during install.
