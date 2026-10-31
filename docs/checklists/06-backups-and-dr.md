# 06. Backups and disaster recovery

Background: [Backups and recovery](../backups-and-recovery.md).

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Retention | `RETENTION="daily=7 weekly=4 monthly=3"` in the config | `M doctor` Backups section | GFS keeps old points without filling the disk |
| 2 | Off-site target | a Spaces bucket + key in `/etc/vps-server-workbench/offsite.env` (600, `OFFSITE_ACCESS_KEY`/`OFFSITE_SECRET_KEY`); `OFFSITE=s3`, `OFFSITE_BUCKET`, `OFFSITE_ENDPOINT` | `M offsite list` works | backups on the same droplet die with it |
| 3 | Encryption key, stored off the server too | `openssl rand -base64 48 > /etc/vps-server-workbench/backup.key` (600), then copy it to your password manager ([set up](../backups-and-recovery.md#set-up)) | you can find the key without the server | an encrypted backup without its key is lost |
| 4 | First backup | `M backup` | `M offsite verify` (download, checksum, decrypt) | an unproven backup isn't a backup |
| 5 | PITR for prd (Postgres) | `PITR=pgbackrest`; `M pitr setup`; `M pitr backup full` | `M pitr status` shows archiving | nightly dumps lose up to a day |
| 6 | Restore test | `M restore-test` | manifest matches, containers removed | proves the dump loads |
| 7 | Schedule everything | `M cron-install` | `/etc/cron.d/docker-db-server-backup` lists backup, doctor, restore-test, PITR, purge-trash | jobs that aren't scheduled don't run |
| 8 | Missed-backup alert | `HEALTHCHECK_URL=` (a check-in URL) or `ALERT_EMAIL=` | the check-in shows a ping after the next backup | silence is the failure mode of backups |
| 9 | DO snapshots for whole-server undo | `bin/workbench do snapshot <id> --name pre-<change> --wait` before risky changes | `do snapshots <id>` | the quickest rollback of a bad upgrade |
| 10 | Monthly drill | [monthly restore drill](monthly-restore-drill.md) | drill notes in `local/<client>/` | the restore procedure must be practised |
