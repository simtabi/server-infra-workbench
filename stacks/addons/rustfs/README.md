# RustFS add-on (experimental)

S3-compatible object storage written in Rust. **Dev and test only.**

- Image `rustfs/rustfs:1.0.4`. It runs as uid 10001, so install chowns the data directory.
- Refused unless you pass `--accept-experimental` (or set `ACCEPT_EXPERIMENTAL=1`). It is always refused when
  `ADDON_ENV` is a protected env (`prd`).
- **Default credentials are refused** (`rustfsadmin`, `minioadmin`, `admin`). Install generates the root key
  into `secrets.env` (600).
- The console (9001) binds to `127.0.0.1` only. Create a key limited to the bucket there; the root key is
  never written for the app, and `laravel-env` leaves `AWS_ACCESS_KEY_ID` empty for you to fill in.
