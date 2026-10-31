# 02. DB setup

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Size for the engines you enable | [sizing](../reference/sizing.md); 2 GB for Postgres + PgBouncer only | `M doctor` RAM line is ok | four engines on 1.9 GB swapped and got OOM-killed |
| 2 | Copy the manager from the workstation | `src/shell/db/remote-run.sh --host <db> --expect-ip <private-ip> --no-upload --dry-run` (or `scp src/shell/db/docker-db-server-manager.sh <db>:~/`) | `ssh <db> sudo /root/docker-db-server-manager.sh --version` | run `scp` on your Mac, not inside the server shell |
| 3 | Starter config | `M init > /etc/docker-db-server-manager.conf`, or `local/<client>/db-server.conf` from `configure` | `EXPECTED_PRIVATE_IP`, `PRIVATE_IP`, `VPC_CIDR` filled | the wrong-server guard refuses to run on another host |
| 4 | Engines: only what the app uses | `ENABLE_MYSQL=0 ENABLE_MARIADB=0` in the config | `M status` lists only those services | less RAM, less to secure and back up |
| 5 | Install | `M install` (keeps an existing `.env` and data) | `M verify` passes | builds the pinned Postgres image with PostGIS + pgvector |
| 6 | Doctor | `M doctor` | `doctor: no problems` | exposure, privileges, TLS, backups, region checks in one run |
| 7 | Ports on the private IP only | `ssh <db> 'sudo ss -tlnp'` | 5432/6432 on `<private-ip>`, nothing on `0.0.0.0` | Docker-published ports bypass ufw |
| 8 | Cloud firewall | `bin/workbench do firewall-apply db --vpc <vpc-uuid> --droplet <id> --dry-run`, then `--yes` | `bin/workbench do firewalls` shows no `WORLD-OPEN` | a second layer that Docker can't bypass |
| 9 | Admin vs app logins | done by `install`/`upgrade` | `M list-users all`: only `vsw_admin` is superuser | the app login must never be a superuser |
| 10 | Adminer (optional) | `M engine enable adminer`, then `bin/workbench tunnels db-tunnel ...` | `ss` shows 127.0.0.1:8081 only | a web UI only through an SSH tunnel |
| 11 | Backups and cron | [06 Backups and DR](06-backups-and-dr.md); `M cron-install` | `/etc/cron.d/docker-db-server-backup` | nothing is protected until the first verified backup |
| 12 | Inventory again | `bin/workbench server inventory --host <db> --pull --client <client>` | the diff shows the stack | record the finished state |
