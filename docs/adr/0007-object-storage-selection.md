# 0007. Object storage: DO Spaces by default, Garage when self-hosted

- Status: Accepted
- Date: 2026-10-31

## Context

Laravel apps need somewhere to put uploads, generated PDFs and exports. Files on the web droplet's disk do
not survive a rebuild, cannot be shared by two web nodes, and end up in the same snapshot as the code.
The options:

- managed DigitalOcean Spaces
- self-hosted S3-compatible stores: Garage, SeaweedFS, RustFS, Ceph RGW
- MinIO, which is no longer a practical choice: in 2025 it stopped publishing community binaries and images
  (pulling `minio/mc` failed when this was written)

The servers are small (2 to 4 GB droplets), run by one person, and are often budget setups for dev and staging.

## Decision

- **DO Spaces is the default** (the `dev-budget` profile and most production profiles). Use a key scoped to
  the bucket. There is nothing to patch, back up or size.
- **Garage is the recommended self-hosted store**. It is one small binary (~256 MB of RAM, estimate) and
  container-tested here. It supports least-privilege keys per bucket, and grows to three nodes in three
  zones without changing the app.
- **SeaweedFS is supported** for setups that want an admin UI or hold very many small files. It defaults to a
  dedicated droplet.
- **RustFS is experimental**: dev and test only. It is refused on protected envs and with default
  credentials, and app keys are created by hand in its console.
- **Ceph is documented only**. It needs three or more nodes, dedicated disks and an operator.
- **One object store per node**. Stores bind to 127.0.0.1 or the VPC address only. All credentials are
  generated on the node, stored in 600 files and never printed.

## Consequences

- The app sees the same `AWS_*` keys whichever store is used. Moving from Garage to Spaces (or back) is an
  `.env` change plus an `rclone sync`.
- A self-hosted store adds a backup duty: object data must be copied off the node. `doctor` reminds you.
- The configurator warns when storage would share a 2 GB web node with PHP. It recommends the db node once
  MySQL/MariaDB are off, or a dedicated droplet.
- Versions are pinned and checked by hand when upgrading. They are not tracked automatically (Dependabot
  does not watch these templates).
