# 10. Incident and lockout

| # | Symptom | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Site returns 500/503 | `bin/workbench web diagnose --host <web> --site <domain> --env <env>`; `--fix --dry-run` for safe fixes | exit 0 | checks status, `.env` keys (names only), DB, migrations, storage, daemons, logs |
| 2 | 503 and an empty DB | `ssh <web> 'cd <site> && php artisan migrate:status'` | migrations listed as Ran | a site in maintenance mode with no tables means the first deploy never migrated |
| 3 | DB unreachable from web | `bin/workbench web check-db-reach --remote <web> <db-private-ip> 6432 5432` | `ok` per port | private vs public IP, 6432 vs 5432, ufw/cloud firewall, containers, region |
| 4 | DB containers unhealthy | `M status`; `M logs postgres`; `M doctor` | all healthy | memory (OOM) is the usual cause on small droplets |
| 5 | Disk full | `ssh <db> 'df -h; sudo du -sh /opt/db/backups/*'` | below 80% | backups prune by `RETENTION`; partial dumps are refused below `MIN_FREE_MB` |
| 6 | Bad upgrade | the upgrade auto-rolls back; otherwise restore the DO snapshot | `M doctor` | the snapshot is the whole-server undo |
| 7 | Lost data | `M restore <dir>` or `M pitr restore --target '...'` (protected env: `--force-prod`) | row counts match the manifest | see [which restore to use](../backups-and-recovery.md) |
| 8 | Can't SSH in | DO console, then `bash fixkeys.sh diagnose --user <u>` | key login works again | [lockout recipe](../recipes/recover-ssh-lockout.md) |
| 9 | Locked out completely | DO recovery ISO, mount the disk, `fixkeys.sh --root /mnt add ...` | boot from disk, log in | the last resort, tested once on a scratch droplet |
| 10 | Afterwards | add a row to [lessons learned](../lessons-learned.md); `server inventory --pull` | lesson written | each incident becomes a rule |
