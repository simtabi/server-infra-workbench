# 09. Upgrades, resizes and engine changes

## OS updates and reboots

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | See what's pending | `bin/siwo server update --host <alias>` (plan only) | list of packages; "reboot required" if a kernel is waiting | know before you change |
| 2 | Snapshot (DB) | `bin/siwo do snapshot <id> --name pre-update --wait` | `do snapshots <id>` | whole-server undo |
| 3 | Upgrade with a reboot window | `bin/siwo server update --host <alias> --yes --backup-first --reboot-window 03:00-05:00` | after the reboot: `ssh <alias> uptime`; `M doctor` | Docker is held so containers don't restart mid-day |

## DB manager upgrade

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Read the changelog | [CHANGELOG](../../CHANGELOG.md) between `M --version` and the new one | you know what changes | new keys have safe defaults, but read them |
| 2 | Config first | compare with `config/db-server.env.example` (the `SIWO_DB_*` keys in the root `.env`) | new keys considered | upgrades never reset data; the config drives them |
| 3 | Upload and plan | `src/shell/db/remote-run.sh --host <db> --expect-ip <ip> -- upgrade --dry-run` | every plan line read | preflight, diff, what will restart |
| 4 | Upgrade | same with `-- upgrade` (offers a snapshot) | `M doctor` clean; app `/up` 200 | verified backup, savepoint, apply, verify, auto-rollback on failure |
| 5 | Re-install cron | `M cron-install` | new jobs listed | new versions add jobs |
| 6 | Restore test | `M restore-test` | pass | proves the new version's backups load |

## Resize

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Decide from data | `M doctor` RAM line; DO memory graph | sustained >80% memory, or alerts firing | in dev, turning engines off is cheaper than resizing |
| 2 | Snapshot, then resize (CPU/RAM only) | `bin/siwo do resize <id> --size s-2vcpu-4gb --dry-run`, then `--yes` | droplet active; `M doctor` | a few minutes of downtime; `--disk` is permanent (can't shrink back) |

## Engines on or off

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Turn an engine off (data kept) | `M engine disable mysql --dry-run`, then without | `M status` no mysql; volume still exists | frees RAM; backup first is automatic |
| 2 | Turn it back on | `M engine enable mysql` | `M verify` | the data is still there |
| 3 | Delete the data for good | `M engine disable mysql --delete-volume` (typed confirmation) | volume gone | only after a verified off-site backup |
