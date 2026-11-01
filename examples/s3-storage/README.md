# Example: self-hosted S3 storage for Laravel files

Made up: Garage on the DB droplet, bound to its VPC IP `10.0.0.5`, data on a DO volume. The app on the web
node uses it as the `s3` disk. SeaweedFS is the alternative; RustFS is experimental (needs
`--accept-experimental`, refused on prd). Choice and trade-offs: [ADR 0007](../../docs/adr/0007-object-storage-selection.md).

```bash
examples/run.sh s3-storage                  # configure checks + `addon plan garage` / `seaweedfs`
bin/siwo addon install garage --role db --bind 10.0.0.5 --data-dir /mnt/volume_nyc3_01/garage --yes   # on the DB node
bin/siwo addon laravel-env garage --out /root/garage.laravel.env    # 600; then `env init --addons`
```

The RPC secret, admin token and app key are generated at install into `secrets.env` (600) and are never printed.

Checklist:

- [ ] Data dir on a volume, not the root disk
- [ ] Bucket and app key created by the install (not the admin token in the app)
- [ ] Off-site copy of the bucket (or accept that it is cache-like data)
