# Checklist: new DB server

1. [ ] Droplet in the same region and VPC as the web servers; size from [sizing](../reference/sizing.md)
       (4 GB for Postgres with several envs, estimate). Note the private IP.
2. [ ] SSH key login works ([set up SSH access](../recipes/set-up-ssh-access.md)); keep the provider console handy.
3. [ ] `bin/workbench server init --host <db> --role db --swap 2G --dry-run`, then `--yes`
       (timezone, swap, packages, Docker, harden).
4. [ ] `bin/workbench server inventory --host <db> --pull --client <client>` and keep the first snapshot.
5. [ ] Copy the manager: `scp src/shell/db/docker-db-server-manager.sh <db>:/root/`.
6. [ ] `sudo /root/docker-db-server-manager.sh init > /etc/docker-db-server-manager.conf`; set
       `EXPECTED_PRIVATE_IP`, `VPC_CIDR`, the engines you need (`engine` count drives RAM).
7. [ ] Environments: `env-init --dry-run ...`, then `--out /etc/docker-db-server-manager.conf`
       ([guide](../database-environments.md#set-it-up)).
8. [ ] `install`, then `verify` and `doctor` (no PROBLEM lines).
9. [ ] `env-apply`, `env-list`.
10. [ ] Off-site key and credentials files (0600), `OFFSITE`, `RETENTION`, `PITR`
        ([backups](../backups-and-recovery.md#set-up)); copy the key off the server.
11. [ ] `pitr setup`, `backup`, `offsite verify`, `restore-test`.
12. [ ] `cron-install`; check `/etc/cron.d/docker-db-server-backup`.
13. [ ] Alerts: `ALERT_EMAIL` or `HEALTHCHECK_URL`; trigger `doctor --alert` once and see it arrive.
14. [ ] `env-creds <env> --out /root/<env>-db.env` (umask 077) for each env and hand them to the web server.
15. [ ] Record the server in the client's `local/<client>/` notes (gitignored): IPs, sizes, what's enabled.
