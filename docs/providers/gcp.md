# Google Cloud (`siwo gcp`)

**Why:** some environments (DR copies, cross-region replicas, backups) run on Google Cloud. The workbench covers
Compute Engine instances, snapshots and firewalls, Cloud DNS and Cloud Storage buckets over the REST APIs
(`compute.googleapis.com`, `dns.googleapis.com`, `storage.googleapis.com`), authenticating with a service-account
key through a signed JWT exchanged at `oauth2.googleapis.com`. `gcloud` is not needed.

## Least-privilege service account

Create a dedicated service account, download one JSON key to a path outside any repo (mode 600), and set
`GOOGLE_APPLICATION_CREDENTIALS` to that path and `GCP_PROJECT` to the project id. The workbench asks Google for
read-only OAuth scopes (`compute.readonly`, `ndev.clouddns.readonly`, `devstorage.read_only`) for reads and the
write scopes only when a write is confirmed; IAM roles decide what is actually allowed:

| Commands | IAM role (project) |
| --- | --- |
| reads (and the live test) | `roles/compute.viewer`, `roles/dns.reader`, `roles/storage.bucketViewer` (+ `roles/storage.objectViewer` for `buckets objects`) |
| instances start/stop/reset/create/delete, snapshots | `roles/compute.instanceAdmin.v1`, `roles/compute.storageAdmin` |
| firewalls | `roles/compute.securityAdmin` |
| Cloud DNS writes | `roles/dns.admin` |
| bucket create/delete | `roles/storage.admin` |

Instances are created **without** a service account attached, so no `iam.serviceAccounts.actAs` is needed.
Prefer granting roles on the project used by the workbench only, and rotate the key (or use short-lived
impersonation outside the workbench).

## Commands

All take `--json` and `--project P` (default `GCP_PROJECT`); writes take `--dry-run`, `--yes`; destructive
writes need `--force`.

**Instances**

- `bin/siwo gcp instances --zone us-east1-b`, `bin/siwo gcp instance show <name> --zone us-east1-b`
- `bin/siwo gcp instance create <name> --zone us-east1-b --size e2-small --disk-gb 20 --tag db --network default`
  (idempotent by name; OS Login and Shielded VM on, no service-account scopes)
- `bin/siwo gcp instance start <name> --zone us-east1-b --wait`, `bin/siwo gcp instance stop <name> --zone us-east1-b`
- `bin/siwo gcp instance reset <name> --zone us-east1-b --force`, `bin/siwo gcp instance delete <name> --zone us-east1-b --force`

**Snapshots**

- `bin/siwo gcp snapshots`, `bin/siwo gcp snapshot us-east1-b <disk> --name pre-upgrade --wait`
- `bin/siwo gcp snapshot-delete <snapshot> --force`

**Firewalls**

- `bin/siwo gcp firewalls` (`WORLD-OPEN` marks rules open to `0.0.0.0/0`)
- `bin/siwo gcp firewall-create allow-ssh-admin --allow tcp:22 --source-ranges <admin-cidr> --target-tags db --priority 1000`
  (a non-web port open to the world needs `--force`)
- `bin/siwo gcp firewall-delete <name> --force`

**Cloud DNS**

- `bin/siwo gcp dns zones`, `bin/siwo gcp dns zone-create example.com --name example-com`,
  `bin/siwo gcp dns zone-delete <zone> --force`
- `bin/siwo gcp dns list <zone> --type A`
- `bin/siwo gcp dns upsert <zone> A app <ip> --ttl 300` (one atomic change: deletes the old set and adds the new)
- `bin/siwo gcp dns delete <zone> A app --force`

**Cloud Storage**

- `bin/siwo gcp buckets list`, `bin/siwo gcp buckets show <bucket>`, `bin/siwo gcp buckets objects <bucket> --prefix db/ --limit 100`
- `bin/siwo gcp buckets create <bucket> --location US --storage-class STANDARD --retention-days 30`
  (uniform bucket-level access, public access prevention enforced, versioning on; `--retention-days N` adds a
  lifecycle rule that deletes objects older than N days, it is not a retention lock)
- `bin/siwo gcp buckets delete <bucket> --force` (must be empty)

## Checklist

- [ ] Key file outside the repo, mode 600; `bin/siwo credentials` shows it set.
- [ ] The service account has only the roles for what you run; no `roles/owner` or `roles/editor`.
- [ ] `bin/siwo gcp firewalls` shows no `WORLD-OPEN` rule on 22 or a database port.
- [ ] Backup buckets have public access prevention, versioning and a lifecycle (`--retention-days`) matching the backup policy.
- [ ] Snapshot a disk before a risky change, and check it in `bin/siwo gcp snapshots`.

## Lessons learned

- **World-open firewall rules are the common accident.** A rule with `0.0.0.0/0` on anything but 80/443 is
  refused without `--force`, and listings flag existing ones.
- **Cloud DNS changes are atomic.** An upsert sends the deletion of the old record set and the addition of the
  new one in one change, so there is no window without a record. Names are relative to the zone unless they end
  with a dot; an absolute name outside the zone is refused.
- **Compute writes are operations.** The API returns an operation to poll; `--wait` follows it to the end and
  reports the operation's own error instead of a generic failure.
- **Buckets default private here**, unlike some older defaults: uniform access and enforced public access
  prevention mean an object ACL can't make a backup public by mistake.
