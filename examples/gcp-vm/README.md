# Example: the same layout on GCP

Made up: project `my-project`, region `us-central1`. A Ploi web VM `web-01` (`10.128.0.6`, tag `siw-web`) and a DB
VM `db-01` (`10.128.0.5`, tag `siw-db`) in a custom VPC `siw` with subnet `10.128.0.0/20`. Off-site backups go to
a GCS bucket `shop-db-backups`. Profile [`production-single`](../../config/profiles/production-single.conf), with
the DigitalOcean-only parts turned off.

**Why:**

- **`CLOUD=gcp`, `REGION=us-central1`.** `configure` then checks GCP region names (a zone such as
  `us-central1-a` is refused with its region), suggests E2 machine types when a node is short of RAM, and
  defaults the off-site endpoint to GCS. A GCP VPC network spans regions, so a second region needs no
  WireGuard tunnel.
- **Nothing in the DB server is DigitalOcean-specific except three settings.** `DO_ALERTS=0` and
  `UPTIME_CHECKS=0` (Uptime Kuma from the profile's `MONITOR_STACKS` does the probing). `STORAGE=none`, since
  Spaces is the DO default. Off-site goes to GCS through its S3-compatible XML API (`OFFSITE_ENDPOINT=
  https://storage.googleapis.com`, `OFFSITE_REGION=auto`, an HMAC key of a service account that can only
  write to the bucket).
- **The private interface is `ens4`, not `eth1`.** A GCP VM has one NIC with the internal IP, and the public
  IP is NAT outside the VM. Set `PRIVATE_IFACE=ens4` (or `PRIVATE_IP=10.128.0.5`) in
  `/etc/docker-db-server-manager.conf` before `install`, or the manager can't find what to bind to.
- **A custom VPC, not `default`.** The default network ships `default-allow-internal` (every port from
  `10.128.0.0/9`, so every VM in the project reaches Postgres) and `default-allow-ssh` from `0.0.0.0/0`.
  [`gcp-firewall.sh`](gcp-firewall.sh) plans three rules on `siw`: 80/443 to the web tag, 5432/6432 from the
  web *tag* to the DB tag, and SSH only from Google's IAP range.
- **Tags, not addresses.** A rule "from tag `siw-web`" follows the web VM through a re-create. A CIDR also
  admits whatever else lands in the subnet later. The DB's own `VPC_CIDR` check stays as a second layer.
- **Snapshots through the workbench, read-only by default.** `bin/siwo gcp snapshot <zone> <disk>`
  takes the same pre-change snapshot as `do snapshot`.

```bash
examples/run.sh gcp-vm      # validate (offline): profile checks, plans, gcp-firewall.sh self-test
bin/siwo configure --profile production-single --client <you> --set CLOUD=gcp --set REGION=us-central1 \
  --set APP=shop --set ALERT_EMAIL=<you@example.com> --set DB_PRIVATE_IP=10.128.0.5 --set WEB_PRIVATE_IP=10.128.0.6 --set VPC_CIDR=10.128.0.0/20 \
  --set OFFSITE_BUCKET=shop-db-backups --set OFFSITE_ENDPOINT=https://storage.googleapis.com --set OFFSITE_REGION=auto \
  --set DO_ALERTS=0 --set UPTIME_CHECKS=0 --set STORAGE=none
examples/gcp-vm/gcp-firewall.sh --network siw --project my-project            # the plan; --apply runs it
bin/siwo gcp instances --zone us-central1-a                                 # read-only
bin/siwo gcp firewalls                                                      # WORLD-OPEN marks 0.0.0.0/0 rules
bin/siwo gcp snapshot us-central1-a db-01 --dry-run                         # before any change
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh gcp-vm`: settings through `configure --dry-run`, plans, the self-test |
| [`gcp-firewall.sh`](gcp-firewall.sh) | the three VPC firewall rules by tag; prints `gcloud` commands, runs them with `--apply` |

Checklist:

- [ ] VMs created with `--network siw --subnet siw-us-central1 --tags siw-web` / `siw-db`; the DB VM with
      `--no-address` (no public IP; Cloud NAT for apt and image pulls)
- [ ] `bin/siwo gcp firewalls` shows no `WORLD-OPEN` rule other than `siw-web-https`
- [ ] `PRIVATE_IFACE=ens4` in the manager's config; `ss -ltn` on `db-01` shows Postgres on `10.128.0.5` only
- [ ] `offsite verify` passes against GCS before you rely on it (the S3 interop path is less exercised than
      Spaces; `PITR_S3_URI_STYLE=path` if pgBackRest can't reach the bucket host)

Lesson: on GCP a VM without a public IP has no internet either (no apt, no Docker Hub) until you add Cloud NAT.
That's the right DB setup, but `server init` fails at the first `apt-get` if NAT comes later.
