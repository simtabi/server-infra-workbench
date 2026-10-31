# SeaweedFS add-on

Master, volume server, filer and S3 gateway run in one container. An optional admin UI runs alongside.

- Image `chrislusf/seaweedfs:4.51`. Only S3 (8333) is published, on `ADDON_BIND`. The admin UI (12535; the
  4.49+ default) is on `127.0.0.1` only with a generated password, and the legacy 23646 listener is off.
  Turn the UI off with `SEAWEED_ADMIN_UI=0`.
- `s3.json` (chmod 600) defines two identities: `vsw-admin` (maintenance) and `vsw-app`, which has
  `Read/Write/List/Tagging` on `STORAGE_BUCKET` only.
- Install creates the bucket with `weed shell` (`s3.bucket.create`).
- Heavier than Garage. The default role is `dedicated`.
