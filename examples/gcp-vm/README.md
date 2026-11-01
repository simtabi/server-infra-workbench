# Example: the same layout on GCP

Made up: project `my-project`, region `us-central1`. A Ploi web VM `web-01` (`10.128.0.6`, tag `vsw-web`) and a DB
VM `db-01` (`10.128.0.5`, tag `vsw-db`) in a custom VPC `vsw` with subnet `10.128.0.0/20`. Off-site backups go to
a GCS bucket `shop-db-backups`. Profile [`production-single`](../../config/profiles/production-single.conf), with
the DigitalOcean-only parts turned off.

**Why:**

- **Nothing in the DB server is DigitalOcean-specific except three settings.** `DO_ALERTS=0` and
  `UPTIME_CHECKS=0` (Uptime Kuma from the profile's `MONITOR_STACKS` does the probing). `STORAGE=none`, since
  Spaces is the DO default. Off-site goes to GCS through its S3-compatible XML API (`OFFSITE_ENDPOINT=
  https://storage.googleapis.com`, `OFFSITE_REGION=auto`, an HMAC key of a service account that can only
  write to the bucket).
- **The private interface is `ens4`, not `eth1`.** A GCP VM has one NIC with the internal IP, and the public
  IP is NAT outside the VM. Set `PRIVATE_IFACE=ens4` (or `PRIVATE_IP=10.128.0.5`) in
  `/etc/docker-db-server-manager.conf` before `install`, or the manager can't find what to bind to. (Leave
  `REGION` alone: it's a DigitalOcean slug that `configure` checks, and nothing here uses it.)
- **A custom VPC, not `default`.** The default network ships `default-allow-internal` (every port from
  `10.128.0.0/9`, so every VM in the project reaches Postgres) and `default-allow-ssh` from `0.0.0.0/0`.
  [`gcp-firewall.sh`](gcp-firewall.sh) plans three rules on `vsw`: 80/443 to the web tag, 5432/6432 from the
  web *tag* to the DB tag, and SSH only from Google's IAP range.
- **Tags, not addresses.** A rule "from tag `vsw-web`" follows the web VM through a re-create. A CIDR also
  admits whatever else lands in the subnet later. The DB's own `VPC_CIDR` check stays as a second layer.
- **Snapshots through the workbench, read-only by default.** `bin/workbench gcp snapshot <zone> <disk>`
  takes the same pre-change snapshot as `do snapshot`.

```bash
examples/run.sh gcp-vm      # validate (offline): profile checks, plans, gcp-firewall.sh self-test
bin/workbench configure --profile production-single --client <you> --set APP=shop --set ALERT_EMAIL=<you@example.com> \
  --set DB_PRIVATE_IP=10.128.0.5 --set WEB_PRIVATE_IP=10.128.0.6 --set VPC_CIDR=10.128.0.0/20 \
  --set OFFSITE_BUCKET=shop-db-backups --set OFFSITE_ENDPOINT=https://storage.googleapis.com --set OFFSITE_REGION=auto \
  --set DO_ALERTS=0 --set UPTIME_CHECKS=0 --set STORAGE=none
examples/gcp-vm/gcp-firewall.sh --network vsw --project my-project            # the plan; --apply runs it
bin/workbench gcp instances --zone us-central1-a                                 # read-only
bin/workbench gcp firewalls                                                      # WORLD-OPEN marks 0.0.0.0/0 rules
bin/workbench gcp snapshot us-central1-a db-01 --dry-run                         # before any change
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh gcp-vm`: settings through `configure --dry-run`, plans, the self-test |
| [`gcp-firewall.sh`](gcp-firewall.sh) | the three VPC firewall rules by tag; prints `gcloud` commands, runs them with `--apply` |

Checklist:

- [ ] VMs created with `--network vsw --subnet vsw-us-central1 --tags vsw-web` / `vsw-db`; the DB VM with
      `--no-address` (no public IP; Cloud NAT for apt and image pulls)
- [ ] `bin/workbench gcp firewalls` shows no `WORLD-OPEN` rule other than `vsw-web-https`
- [ ] `PRIVATE_IFACE=ens4` in the manager's config; `ss -ltn` on `db-01` shows Postgres on `10.128.0.5` only
- [ ] `offsite verify` passes against GCS before you rely on it (the S3 interop path is less exercised than
      Spaces; `PITR_S3_URI_STYLE=path` if pgBackRest can't reach the bucket host)

Lesson: on GCP a VM without a public IP has no internet either (no apt, no Docker Hub) until you add Cloud NAT.
That's the right DB setup, but `server init` fails at the first `apt-get` if NAT comes later.
