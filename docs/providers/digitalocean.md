# DigitalOcean (`siwo do`)

**Why:** the database and app droplets live on DigitalOcean. The workbench covers what a rollout and its
day-two operations need (droplets, resizes, snapshots, volumes, VPCs, cloud firewalls, monitoring and uptime
alerts, SSH keys, Spaces keys, DNS, reserved IPs, projects and tags) through the v2 REST API
(`https://api.digitalocean.com/v2`), so `doctl` is optional and every write is planned, confirmed and audited.

## Least-privilege token

Create a **custom-scoped** personal access token (Control panel → API → Generate New Token → Custom Scopes) and
store it as `DIGITALOCEAN_TOKEN` (env or the credentials file). Grant only what you run:

| Commands | Scopes |
| --- | --- |
| every read below (and the live test) | `account:read`, `droplet:read`, `regions:read`, `sizes:read`, `snapshot:read`, `block_storage:read`, `vpc:read`, `firewall:read`, `monitoring:read`, `uptime:read`, `ssh_key:read`, `spaces_key:read`, `domain:read`, `reserved_ip:read`, `project:read`, `tag:read`, `actions:read` |
| droplet create, power, resize, snapshot | `droplet:create`, `droplet:update`, `image:read` |
| droplet / snapshot delete | `droplet:delete`, `snapshot:delete` |
| volumes | `block_storage:create`, `block_storage:update`, `block_storage:delete`, `block_storage_action:create` |
| VPCs | `vpc:create`, `vpc:update`, `vpc:delete` |
| firewalls | `firewall:create`, `firewall:update`, `firewall:delete` |
| alerts / uptime | `monitoring:create`, `monitoring:delete`, `uptime:create`, `uptime:delete` |
| SSH keys | `ssh_key:create`, `ssh_key:update`, `ssh_key:delete` |
| Spaces keys | `spaces_key:create_credentials`, `spaces_key:delete` |
| domains / DNS | `domain:create`, `domain:update`, `domain:delete` |
| reserved IPs | `reserved_ip:create`, `reserved_ip:update`, `reserved_ip:delete` |
| projects / tags | `project:assign_resource`, `tag:create`, `tag:delete` |

A read-only token (`api:read`) is enough for every listing and for `--dry-run` of any write. Give tokens an
expiry, one per workstation, and revoke on leave.

## Commands

All take `--json`; writes take `--dry-run`, `--yes`; destructive writes need `--force`.

**Account and catalog**

- `bin/siwo do account` checks the token.
- `bin/siwo do regions` and `bin/siwo do sizes --region nyc3` list the slugs for `--region` / `--size`.

**Droplets**

- `bin/siwo do droplets --tag db` and `bin/siwo do droplet <id>`
- `bin/siwo do droplet-create <name> --region nyc3 --size s-2vcpu-4gb --ssh-keys <key-id> --vpc <vpc-uuid> --tag db`
  (idempotent by name; image from `--image`, `SIWO_DROPLET_IMAGE`, else the newest Ubuntu LTS; `--image latest`
  asks the API)
- `bin/siwo do power <id> reboot` (`power_off` / `power_cycle` need `--force`)
- `bin/siwo do resize <id> --size s-4vcpu-8gb` shuts down, resizes and powers on. `--disk` grows the disk
  permanently and needs `--force`.
- `bin/siwo do droplet-delete <id> --force`

**Snapshots**

- `bin/siwo do snapshots` / `bin/siwo do snapshots <droplet-id>`
- `bin/siwo do snapshot <droplet-id> --name pre-upgrade --wait`
- `bin/siwo do snapshot-delete <snapshot-id> --force`

**Volumes (block storage)**

- `bin/siwo do volumes list --region nyc3`
- `bin/siwo do volumes create <name> --region nyc3 --size-gb 100 --filesystem ext4`
- `bin/siwo do volumes attach <volume-id> --droplet <id> --wait` / `bin/siwo do volumes detach <volume-id> --droplet <id>`
- `bin/siwo do volumes resize <volume-id> --size-gb 200 --force` (grow only)
- `bin/siwo do volumes delete <volume-id> --force`

**VPCs**

- `bin/siwo do vpcs list --region nyc3`, `bin/siwo do vpcs members <vpc-id>`
- `bin/siwo do vpcs create <name> --region nyc3 --ip-range <cidr> --description "db network"`
- `bin/siwo do vpcs default <vpc-id>` makes it the region default (no-op if it already is).
- `bin/siwo do vpcs delete <vpc-id> --force` refuses the default VPC and a VPC that still has members.

**Cloud firewalls**

- `bin/siwo do firewalls` (`WORLD-OPEN` marks non-web ports open to everyone)
- `bin/siwo do firewall-apply db --vpc <vpc-uuid> --ssh-from <admin-cidr> --droplet <id>` creates or updates
  the preset.
- `bin/siwo do firewall-delete <firewall-id> --force`

**Monitoring and uptime**

- `bin/siwo do alerts list`, `bin/siwo do alerts standard --email ops@example.com --tag db`
- `bin/siwo do alerts create --type disk --value 85 --window 5m --email ops@example.com --tag db`
- `bin/siwo do alerts delete <uuid> --force`
- `bin/siwo do uptime checks`, `bin/siwo do uptime state <check-id>`, `bin/siwo do uptime alerts <check-id>`
- `bin/siwo do uptime check-create <name> <url> --type https --regions us_east,eu_west`
- `bin/siwo do uptime alert-create <check-id> down --email ops@example.com --period 2m`
- `bin/siwo do uptime check-delete <check-id> --force`

**SSH keys** (an alias for [`siwo keys account`](../tools/ssh-keys.md))

- `bin/siwo do ssh-keys list`, `bin/siwo do ssh-keys add ...`, `bin/siwo do ssh-keys rename ...`, `bin/siwo do ssh-keys remove ...`

**Spaces access keys**

- `bin/siwo do spaces-keys list`
- `bin/siwo do spaces-keys create <name> --bucket backups --permission readwrite --out ~/.config/server-infra-workbench/spaces-backups.key`
  writes the secret key to the file (mode 600) and prints only the access key id.
- `bin/siwo do spaces-keys delete <access-key> --force`

**Domains and DNS**

- `bin/siwo do domains list`, `bin/siwo do domains create <domain>`, `bin/siwo do domains delete <domain> --force`
- `bin/siwo do dns list <domain> --type A`
- `bin/siwo do dns upsert <domain> CNAME www <domain>. --ttl 1800` creates, updates or no-ops.
- `bin/siwo do dns delete <domain> <record-id> --force`

**Reserved IPs**

- `bin/siwo do reserved-ips list`, `bin/siwo do reserved-ips create --region nyc3`
- `bin/siwo do reserved-ips assign <ip> --droplet <id>`, `bin/siwo do reserved-ips unassign <ip>`
- `bin/siwo do reserved-ips delete <ip> --force`

**Projects and tags**

- `bin/siwo do projects list`, `bin/siwo do projects resources <project-id>`, `bin/siwo do projects assign <project-id> do:droplet:<id>`
- `bin/siwo do tags list`, `bin/siwo do tags create <tag>`, `bin/siwo do tags attach <tag> <id> --type droplet`,
  `bin/siwo do tags detach <tag> <id>`, `bin/siwo do tags delete <tag> --force`

## Checklist

- [ ] Token is custom-scoped, has an expiry and lives in the credentials file (mode 600), not in shell history.
- [ ] `bin/siwo do account` passes; `bin/siwo credentials` shows it set.
- [ ] New droplets go into a non-default VPC with a `db` / `web` tag, and `firewall-apply` covers that tag.
- [ ] `bin/siwo do firewalls` shows no `WORLD-OPEN` row you did not intend.
- [ ] `alerts standard` and an uptime check exist for every production droplet.
- [ ] Snapshot before `resize`, `power_off` or deleting anything; check it with `bin/siwo do snapshots <droplet-id>`.
- [ ] Spaces keys are per bucket, `readwrite` at most, and the `--out` file is outside the repo.

## Lessons learned

- **The default VPC can't be deleted**, and neither can a VPC with members. The CLI checks both first instead of
  letting the API return a 422 halfway through a cleanup. Make another VPC the default first.
- **Volumes only grow.** The API refuses to shrink, and growing is permanent, so `volumes resize` refuses a
  smaller size locally and needs `--force`. Grow the filesystem on the droplet afterwards (`resize2fs` / `xfs_growfs`).
- **`resize --disk` is one-way too**: a droplet with a grown disk can never move back to a smaller size.
  Without `--disk` only CPU/RAM change and the resize stays reversible.
- **Spaces secrets are shown once.** The API returns the secret only in the create response, so the CLI writes it
  to the `--out` file before printing anything; a lost secret means a new key. `fullaccess` across all buckets
  is refused without `--force`.
- **DNS data needs a trailing dot** for hostnames (CNAME, MX, NS); the client adds it so `www` → `example.com.`
  does not become `example.com.example.com`.
- **Uptime and monitoring alerts are separate APIs.** Monitoring alerts watch droplet metrics; uptime checks
  watch a URL from outside. Production wants both.
