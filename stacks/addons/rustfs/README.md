# RustFS add-on (experimental)

S3-compatible object storage written in Rust. **Dev and test only.**

- Image `rustfs/rustfs:1.0.4`. It runs as uid 10001, so install chowns the data directory.
- Refused unless you pass `--accept-experimental` (or set `ACCEPT_EXPERIMENTAL=1`). It is always refused when
  `ADDON_ENV` is a protected env (`prd`).
- **Default credentials are refused** (`rustfsadmin`, `minioadmin`, `admin`). Install generates the root key
  into `secrets.env` (600).
- The console (9001) binds to `127.0.0.1` only.
- Install creates the bucket and an **app key limited to it**: an IAM user (`RUSTFS_APP_KEY_ID` /
  `RUSTFS_APP_SECRET` in `secrets.env`) with the policy `vsw-app-<bucket>` (get/put/delete objects, list the
  bucket; no bucket create/delete, no admin). The calls go to `/rustfs/admin/v3` from inside the container,
  signed with the root key, with credentials passed on curl's stdin. `laravel-env` writes the app key; the
  root key is never written for the app. `doctor` checks that the app key exists.
