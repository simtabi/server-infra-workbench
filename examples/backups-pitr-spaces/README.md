# Example: nightly dumps + PITR to DO Spaces

Made up: DB droplet `db-01` (`10.0.0.5`) in `nyc3`, app `shop`, a Spaces bucket `shop-db-backups` in `nyc3`.
Profile [`production-single`](../../config/profiles/production-single.conf): `PITR=pgbackrest`, `OFFSITE=s3`,
GFS retention `daily=14 weekly=8 monthly=12 yearly=2`. Full guide:
[backups and recovery](../../docs/backups-and-recovery.md).

**Why:**

- **Two kinds of backup, for two kinds of loss.** Nightly logical dumps (`backup`) survive almost anything
  and restore one engine or database; they lose up to 24 h. pgBackRest (`pitr`) archives the WAL
  continuously, so a bad migration at 09:14 can be undone to 09:13. It rewinds the *whole* Postgres
  cluster, so you want both.
- **Off the droplet, encrypted before it leaves.** A snapshot on the same account dies with the account, or
  with ransomware on the host. Dumps are encrypted with `backup.key` (AES-256) and the pgBackRest repo with
  `PITR_CIPHER_PASS`, on the server, so Spaces only ever holds ciphertext.
- **The keys are generated here, and escrowed by you.** [`offsite-creds.sh`](offsite-creds.sh) writes both to
  `/etc/vps-server-workbench` (600). The Spaces key pair is typed at a hidden prompt, never in argv or shell
  history. Losing the droplet *and* the keys means the backups are noise. Copy the folder into the password
  manager the same day.
- **Same region, separate bucket.** `nyc3` keeps WAL pushes fast (`archive_command` waits on each one). The
  bucket holds backups only, with a key scoped to it, versioning on, and no delete permission if your plan
  allows. A compromised server then can't erase its own history.
- **Proven by cron, not by hope.** `cron-install` adds a weekly `restore-test`: last night's dump goes into
  throwaway containers with no network, and the manifest is compared. It alerts `ALERT_EMAIL` on a
  mismatch. `doctor --alert` runs hourly and warns when a backup, off-site copy or restore test is too old.

```bash
examples/run.sh backups-pitr-spaces      # validate (offline): profile checks, offsite-creds.sh self-test
bin/workbench configure --profile production-single --client <you> --set APP=shop --set ALERT_EMAIL=<you@example.com> \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20 \
  --set OFFSITE_BUCKET=shop-db-backups --set OFFSITE_REGION=nyc3
# DO control panel: bucket shop-db-backups in nyc3 (versioning on), an access key limited to that bucket
# DB server, as root: the credentials once (prompts; values never shown), then escrow the folder
scp examples/backups-pitr-spaces/offsite-creds.sh db-01:/tmp/ && ssh -t db-01 'sudo bash /tmp/offsite-creds.sh && rm /tmp/offsite-creds.sh'
sudo /root/docker-db-server-manager.sh upgrade --dry-run    # shows PITR, the off-site settings, the image change
sudo /root/docker-db-server-manager.sh upgrade
sudo /root/docker-db-server-manager.sh pitr setup           # stanza, check, first full backup
sudo /root/docker-db-server-manager.sh backup               # dumps, manifest, GFS prune, encrypted copy to Spaces
sudo /root/docker-db-server-manager.sh offsite verify       # download, checksum, decrypt, verify
sudo /root/docker-db-server-manager.sh restore-test         # into throwaway containers, compare
sudo /root/docker-db-server-manager.sh cron-install         # dumps nightly, PITR full Sunday + diff daily, tests
sudo /root/docker-db-server-manager.sh pitr status
```

| When | What | Where it goes |
|---|---|---|
| continuously | WAL segments (`archive_command`) | pgBackRest repo in the bucket, `PITR_REPO_PATH` |
| 02:30 Sun / Mon-Sat | `pitr backup full` / `diff` | same repo; kept `PITR_DAYS` (14) |
| 03:15 daily | `backup --cron`: dumps, GFS prune, `offsite backup` | `/opt/db/backups`, then the bucket |
| 05:00 Sun | `restore-test --cron` | throwaway containers; alert on mismatch |
| hourly :07 | `doctor --alert` | email when anything above is late or failing |

Recovery (practise it monthly on a scratch droplet: [drill](../../docs/checklists/monthly-restore-drill.md)):

```bash
sudo /root/docker-db-server-manager.sh pitr restore --target '2026-10-31 09:13:00+00'   # whole cluster, to a time
sudo /root/docker-db-server-manager.sh offsite list && sudo /root/docker-db-server-manager.sh offsite fetch <name>
sudo /root/docker-db-server-manager.sh restore /opt/db/backups/<ts> postgres            # a nightly dump
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh backups-pitr-spaces`: settings through `configure --dry-run`, the self-test |
| [`offsite-creds.sh`](offsite-creds.sh) | writes `offsite.env` + `backup.key` (600) once; never replaces or prints a value |

Checklist:

- [ ] `/etc/vps-server-workbench` (both files) is in the password manager, checked by opening it there
- [ ] `pitr status` shows a full backup and a recent WAL archive; `offsite verify` passes
- [ ] the first `restore-test` alert email arrived (proves the alert path, not just the test)
- [ ] a monthly drill restores to a scratch droplet from the bucket alone, with the escrowed keys

Lesson: a `pitr restore --target` time is UTC (`+00`). The time a user reports ("about 9:15") is in their zone.
Convert it first, and pick a minute *before* the mistake.
