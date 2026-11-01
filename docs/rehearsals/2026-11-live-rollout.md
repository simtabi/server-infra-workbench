# Live rollout rehearsal, 2026-11

A full dress rehearsal of the [live rollout runbook](../runbooks/live-rollout.md)
(tasks 1-15) and a separate Garage cluster test, run on throwaway droplets
before touching production. Nothing in production was changed; the only action
on the real database droplet was taking a snapshot to clone from.

Hostnames, addresses and client names are left out on purpose.

## Setup

| Item | What was used |
|---|---|
| Database | A droplet restored from a snapshot of the production DB host (s-2vcpu-2gb) |
| Web | A fresh Ubuntu 26.04 droplet standing in for the app host (s-1vcpu-1gb) |
| Offsite / PITR repo | A 3-node Garage cluster (s-1vcpu-1gb each), replication 3, behind a TLS front with a private CA |
| Network | An isolated VPC in its own region, so the clone could not reach production |
| Access | A throwaway SSH key, deleted at the end |

### Deviations from the runbook

- **Region**: the production region had no basic sizes on offer, so the
  rehearsal ran in a neighbouring region (the snapshot was transferred).
- **Isolated VPC** instead of the production VPC.
- **Passwordless sudo** was enabled for the admin user on the clone only, so the
  scripted run did not need a password prompt.
- **Cron was disabled** on the clone so it could not run production jobs.
- **Monitoring hub** (task 14) went on the DB node in role `both`, because the
  web host is a panel-managed host without Docker (see the bugs below).
- **Task 15** (app env) ran on a Garage node against a fake site and a fake DB
  env file.
- **Garage S3 over TLS**: Garage serves plain HTTP, so a Caddy front with a
  private CA was added to exercise the `PITR_S3_CA_FILE` path end to end.

## Results

| Task | Result | Time | Notes |
|---|---|---|---|
| 1. Snapshot | PASS | 105 s | |
| 2. Upgrade (dry run, then real) | PASS after 3 fixes | dry 6 s, real 73 s | `--allow-unhealthy`, legacy network migration, `rebind-ip` |
| 3 | PASS | 26 s | |
| 4 | PASS | 19 s | |
| 5 | PASS | 36 s | |
| 6. WireGuard / DB reach | PASS after fix | | Tunnel /24 overlapping the VPC is now refused |
| 7. Cloud firewall | PASS | | |
| 8. Backup + offsite | PASS after fix | 7 s | Backup, upload, verify (checksum + decrypt), list |
| 9. Cron + restore test | PASS | 63 s | Doctor's only problem was PITR before setup (now a warning) |
| 10. PITR | PASS after 3 fixes | upgrade 80 s, setup 38 s, restore 18 s | Dropped table restored to a marker time |
| 11. DO alerts | PASS | ~1 s each | Dry run, create, re-run "no change", delete |
| 12. Retire old image | PASS after fix | 12 s | Old tag now retired |
| 13. TLS verify-full | PASS | 105 s | `openssl verify` OK from the web host on 5432 and 6432 |
| 14. Monitoring | PASS (deviation) | 76 s | Hub + agent + uptime on the DB node; doctor 0 problems |
| 15. App env | PASS (deviation) | 2 s | Dry run, apply, check; file mode 600 |

### Garage cluster (run B)

- 3 nodes joined, layout applied, bucket and key created, doctor healthy 3.
- A 5 MB object written through one node read back identically from another.
- **One node down (2/3)**: writes and reads kept working.
- **Two nodes down (1/3)**: writes were refused, as expected with replication 3.
- **Restart**: the returning node served the object; doctor went from 2 to 3
  healthy about 50 s after the restart.
- PITR to S3 on Garage was covered by task 10.

## Bugs found and fixed

Database manager:

- The upgrade could not proceed on an unhealthy legacy stack: added
  `--allow-unhealthy`.
- Legacy Docker network names are migrated during upgrade.
- New `rebind-ip` command for moving the published port to a new private IP.
- Offsite uploads: a global `AWS_CA_BUNDLE` broke rclone; the CA is now passed
  per tool (`AWS_CA_BUNDLE` for the AWS CLI, `RCLONE_CA_CERT` for rclone), and
  `RCLONE_CONFIG=/dev/null` silences "config file not found".
- `doctor` printed an ERR trap line on failure, and warned about
  unattended-upgrades even when APT::Periodic had it enabled.
- `pitr setup` mistook a Docker error for the pgBackRest version.
- An upgrade that turns PITR on rolled back because the stanza did not exist yet;
  the missing stanza is now a warning during upgrade.
- pgBackRest inside the container could not resolve a private S3 name (Docker DNS
  ignores the host `/etc/hosts`): new `PITR_S3_HOST_IP` adds `extra_hosts`.
- The old custom image tag was never retired on stacks without `stack.env`, nor
  on an "already up to date" upgrade.

Other tooling:

- `remote-run.sh` uploads to `.vsw-upload-*` staging names, so a root login works.
- `confirm()` no longer prints `/dev/tty` noise without a terminal.
- `net` WireGuard setup refuses a tunnel subnet that overlaps a host network.
- `monitor plan` says when Docker with the compose plugin is missing.

Docs: rclone install, offsite CA and hosts, "set `PITR=pgbackrest`, upgrade, then
`pitr setup`", `--yes` for scripted upgrades and DO alert changes, monitoring hub
needs Docker, and `addon.sh laravel-env` before `env init --addons`.

## Noted, not fixed

- `.bak.<ts>` files in `/etc/apt/apt.conf.d` trigger an apt filename notice (cosmetic).
- `do snapshots` shows an empty droplet column.
- The image build shows an `InvalidDefaultArgInFrom` warning and debconf tty noise.
- ufw stays inactive on nodes after `server init --role db` (the VPC isolated them here).
- Doctor wording for "replication 3 needs at least that many" nodes is awkward.

## Cleanup and cost

All droplets, snapshots, the firewall and the throwaway SSH key were deleted
after about 1.6 hours. The rehearsal VPC could not be deleted because
DigitalOcean made it the region's default VPC (it is free). Approximate cost:
**under $0.20** (five droplets for about 2 billed hours, four short-lived
droplets created in the wrong region, and a few hours of snapshot storage).
