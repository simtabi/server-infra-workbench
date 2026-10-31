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
- Grow to three nodes in three zones for redundancy. Raise `replication_factor` only on a new cluster;
  see the Garage docs on changing it.

Note: the app secret is passed to `garage key import` inside the container, so it is briefly visible to root
in the process list during install.
