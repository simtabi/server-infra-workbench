# Live tests (real DigitalOcean resources)

`make it` proves almost everything in Docker on one machine. Three things cannot be proven there, so they
have opt-in live tests that create throwaway DigitalOcean resources, check them, and delete them again:

| Test | Proves | Creates | Worst case | Typical |
|---|---|---|---|---|
| [`pitr-spaces-live.sh`](../tests/live/pitr-spaces-live.sh) | Postgres PITR to a real Spaces bucket: host-style URLs, the real endpoint and its public CA, a bucket-scoped key (403 on other buckets), restore to a time, encrypted repo, no secret in any output | 1 Spaces bucket, 2 Spaces keys (the DB stack runs in Docker on your machine) | $0.01 | ~6 min |
| [`server-live.sh`](../tests/live/server-live.sh) | `server init --host` from your workstation on a fresh Ubuntu droplet: dry run changes nothing, swap (2G, 600, fstab, swappiness), Docker from its signed apt repo, a second run changes nothing, `harden --check`, `status --json`, no temp copies left, both survive a reboot | 1 droplet, VPC, firewall, ssh key | $0.01 | ~7 min |
| [`garage-live.sh`](../tests/live/garage-live.sh) | a 3-node Garage cluster over a real VPC: install, refused join without secrets, joins, layout in 3 zones, S3/RPC on VPC addresses only (admin on loopback, public address closed), write on n1 read on n3, one node down (quorum kept, doctor warns), catch-up | 3 droplets, VPC, firewall, ssh key | $0.03 | ~10 min |

**Why not in CI:** they spend money, need a DigitalOcean token with write access, and take minutes. They
never run in `make ci`, `make it` or the GitHub workflow. Run them before a release that touches backups,
server setup or the Garage add-on, and after a change to any of these code paths.

## Run

```sh
make live-test                        # dry runs: the plan and the worst-case cost of each; nothing is created
make live-test LIVE_ARGS=--yes        # runs all three (spends about $0.05)
bash tests/live/garage-live.sh --yes  # one test
bash tests/live/server-live.sh --yes --region tor1 --max-usd 0.10 --timeout 30
make live-sweep                       # lists anything a killed run left behind
make live-sweep LIVE_ARGS=--yes       # deletes it
bash tests/live/sweep.sh --buckets    # also lists Spaces buckets (makes and deletes a throwaway key)
```

Needs `doctl` signed in (`doctl auth init`), `jq`, `curl`, `ssh`, `python3`, `openssl`, and Docker for the
Spaces test. Options shared by every test: `--yes`, `--region` (default `tor1`), `--size` (default
`s-1vcpu-1gb`), `--max-usd`, `--timeout MIN` (5 to 240), `--create-default-vpc`. Run them from a terminal you
will keep open; a killed run is cleaned up by `make live-sweep LIVE_ARGS=--yes`.

## Safety rails (tests/live/lib)

- **Dry run by default.** Without `--yes` a test prints its plan and worst-case cost and creates nothing.
- **Cost guard.** Worst case = hourly price of the droplets x the timeout rounded up to whole hours (DO bills
  per started hour) + fixed costs. Above `--max-usd` the test refuses to start. Every run appends start and end
  lines (seconds, estimate, leftovers, month-to-date usage) to `~/.local/state/siw-livetest/cost.log`.
- **Teardown always runs.** An EXIT/INT/TERM/HUP trap tears down; during teardown further signals are
  ignored so a second Ctrl-C cannot leave paid resources behind. A watchdog sends TERM after `--timeout`.
- **Only its own resources.** Everything is named `siwlt-<run>-*` and droplets carry the tags `siw-livetest` and
  `siw-livetest-<run>`. Teardown deletes droplets by the run tag only after checking that every one also has the
  name prefix and the base tag; anything else stops it. Your existing droplets, VPCs and keys are never touched.
- **Its own network.** Each run makes a non-default VPC in a free `10.200-250.x.0/24`, a throwaway ed25519 key,
  and a cloud firewall that allows ssh from your public IPv4 only and all traffic inside the VPC.
- **No first VPC by accident.** The first VPC in a region becomes its default and can never be deleted. A region
  without a VPC is refused unless you pass `--create-default-vpc`, which creates `default-<region>` (free, kept)
  before the test VPC.
- **Verified cleanup.** After teardown the account is listed again; any `siwlt-<run>-*` droplet, firewall, ssh
  key or VPC left is reported as LEFTOVERS and the run fails.
- **No secrets or addresses in output.** Spaces keys go to 600 files and reach curl on stdin; IPs are not
  printed; each test greps its outputs for its secrets.

## DigitalOcean Spaces billing

Spaces is a $5/month subscription (250 GiB storage, 1 TiB transfer) that **starts when the first bucket is
created and ends when the last bucket is deleted**, prorated hourly. There is no separate on/off switch in the
API or doctl: `pitr-spaces-live.sh` deletes its bucket, checks the region's bucket list, and reports
`buckets left: 0 (no bucket: the Spaces subscription ends, billing stops)`. `sweep.sh --buckets` checks every
Spaces region. Spaces access keys cost nothing; the test deletes both of its keys and verifies none is left.

To check or stop it by hand: control panel, **Spaces Object Storage**, **Buckets**. With no bucket listed, nothing
is billed. Otherwise open each bucket, **Settings**, **Delete this Spaces Bucket**, type the name. Keys are under
**Spaces Object Storage**, **Access Keys**.

## Regions

The basic `s-1vcpu-1gb` size is not offered in every region (in late 2026 not in nyc1-3). The tests check the
size is offered in the region and refuse otherwise. The default `tor1` had no VPC in the account this was built
on, so the first run used `--create-default-vpc` and `default-tor1` now exists (free).

## Adding a live test

Source `tests/live/lib/live.sh`, set `LIVE_TIMEOUT_MIN` and `LIVE_MAX_USD`, call `live_args "$@"`, then
`live_begin <name> <droplets> <fixed-usd>`, `live_vpc_create`, `live_sshkey_create`, `live_firewall_create`,
`live_droplets_create n1 ...`. Use `live_ssh n1 ...` and `scp ... n1:` (the run's ssh config is first on PATH,
so tools that run `ssh <alias>`, like `--host`, use it). Register extra cleanup with
`LIVE_CLEANUP_HOOKS+=(fn)`. Report with `live_ok` and `live_fail`. Spaces helpers are in `tests/live/lib/spaces.sh`.

## Optional: from GitHub Actions

Not set up on purpose. If wanted, add a `workflow_dispatch`-only workflow that runs `make live-test
LIVE_ARGS=--yes` with a `DIGITALOCEAN_ACCESS_TOKEN` repository secret (write scope, ideally a dedicated team), in
an environment with required reviewers. The ssh firewall rule allows the runner's public IP for the run.
