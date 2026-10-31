# New project in 10 minutes

From two fresh Ploi droplets in one DigitalOcean VPC to a deployed app. The
placeholders are: project `myproject`, site `app.example.com`, SSH aliases
`myproject-web` / `myproject-db`, DB private IP `10.0.0.5`. A filled-in set of
files for this made-up project is in
[`examples/generic-laravel/`](../examples/generic-laravel/README.md).

```mermaid
flowchart LR
    a["1. SSH aliases"] --> b["2. init config"] --> c["3. install DB stack"] --> d["4. DB_* to web .env"] --> e["5. deploy settings"] --> f["6. deploy + daemons"]
```

**1. SSH** ([ssh-access.md](recipes/set-up-ssh-access.md)). One key per host, added in Ploi for user `ploi`:

```sh
ssh myproject-db whoami && ssh myproject-web whoami      # both: ploi
```

**2. DB config.** `init` detects the private IP and VPC range and prints a config with no secrets:

```sh
mkdir -p examples/myproject     # or anywhere outside the repo
ssh myproject-db 'bash -s -- init' < shell/db/docker-db-server-manager.sh > examples/myproject/db-server.conf
```

Edit it: `PG_USER`/`PG_DB` (e.g. `myproject`), and switch off engines you don't
need (`ENABLE_MYSQL=0`, `ENABLE_MARIADB=0`, ...). All settings:
[`config/db-server.env.example`](../config/db-server.env.example).

**3. Install the DB stack**, with nightly backups, and print the `DB_*` lines:

```sh
shell/db/remote-run.sh --host myproject-db --expect-ip 10.0.0.5 \
  --config examples/myproject/db-server.conf -- install, cron-install, doctor, env > ~/myproject-db.env
```

**4. Point the web server at it** (check reachability first; no passwords needed for that):

```sh
shell/web/check-db-reach.sh --remote myproject-web 10.0.0.5
# keep only the DB_* lines from step 3's output in ~/myproject-db.env, then:
shell/web/update-env-db.sh --remote myproject-web --site app.example.com --from ~/myproject-db.env
rm ~/myproject-db.env
```

**5. Deploy script.** Copy [`shell/deploy/ploi-deploy.sh`](../shell/deploy/ploi-deploy.sh),
set the SETTINGS block (`SITE_DOMAIN`, `PRESET=laravel` or `generic`, `APP_SUBDIR`,
any hooks; see [deploy.md](tools/deploy-script.md#settings)) and paste it into Ploi →
site → Deploy script. Keep your SETTINGS block in `examples/myproject/` too.

**6. Deploy** in Ploi. If it stops, it says exactly which `.env` keys or
`install.env` values to fill. Then add the queue worker and scheduler daemons
([daemons.md](recipes/run-daemons.md)) and check the server with
`remote-run.sh ... -- doctor` and [security.md](security.md).

Not Laravel? Use `PRESET=generic` and set `BUILD_CMDS`, `FIRST_INSTALL_CMD`,
`MIGRATE_CMD` and `HEALTHCHECK_CMD` to whatever your app needs; every hook is optional.

## Post-setup checklist

| ✔ | Check | Where / command |
|---|---|---|
| ☐ | A backup ran and is complete | Mac: `remote-run.sh … -- backup`, then on the DB server `sudo ls -l /opt/db/backups` (dated folders, no `.partial-*`) |
| ☐ | A backup restores ([not automatic yet](status.md#restore-test)) | scratch droplet: `restore <dir> all`, then `verify` |
| ☐ | Nightly backup cron installed | DB server: `cat /etc/cron.d/docker-db-server-backup` (contains `DBM_CONFIG=`) |
| ☐ | Offsite copy (optional) | `BACKUP_HOOK` in the config |
| ☐ | Unattended upgrades on, both servers | `systemctl is-active unattended-upgrades` ([security.md](security.md#updates-and-reboots)) |
| ☐ | No pending reboot | `ls /var/run/reboot-required` (reboot if present) |
| ☐ | Firewall: default deny, DB ports only from the VPC | DB server, as root: `sudo ufw status verbose`, `sudo /root/docker-db-server-manager.sh doctor` |
| ☐ | DB ports not public | `doctor`, or `ss -tlnH` (only the private IP) |
| ☐ | Queue worker and scheduler running | web: `pgrep -af 'queue:work\|schedule:work'` ([daemons.md](recipes/run-daemons.md)) |
| ☐ | Ploi's `.env` editor edits the shared file | web: `ls -l /home/ploi/<site>/.env` (symlink to `<site>-shared/.env` when the app root differs) |
| ☐ | `.env` files are 600 | web: `stat -c '%a %n' /home/ploi/<site>-shared/.env*` |
| ☐ | First install finished | web: `ls /home/ploi/<site>-shared/.first-install-done` |
| ☐ | Site responds | Mac: `curl -sI https://<site>` → `200`/`302` (for a 503, see [troubleshooting](troubleshooting.md#503-after-deploy--first-install-never-finished)) |
| ☐ | Alerts set up ([gap](status.md#monitoring)) | uptime check + DO/Ploi alerts |
