# Security and operations

## Firewall and Docker

- **Docker-published ports bypass ufw.** Docker writes its own iptables rules
  ahead of ufw's, so `ufw deny 5432` does **not** block a port that a container
  publishes on `0.0.0.0`. The manager therefore publishes every DB port on the
  private IP only (`PRIVATE_IP:5432:5432`); the ufw rules for `VPC_CIDR` are a
  second layer. Never change a compose file to `"5432:5432"`.
- Check it: `docker-db-server-manager.sh doctor` fails if any DB port listens on
  `0.0.0.0`/`[::]` or on a public address. By hand: `ss -tlnH | awk '{print $4}'`.
- ufw should be `default deny incoming` with `22` (and on the web server `80`,
  `443`) open. `doctor` checks the default policy (needs root).
- DigitalOcean cloud firewalls are an extra layer worth having: allow 22 from
  your IPs, 80/443 to the web droplet, and nothing public to the DB droplet.

## Encryption on the private network

Traffic between the web and DB droplets uses the DigitalOcean VPC without TLS.
For options, see [status.md](status.md#private-network-encryption).

## Updates and reboots

```sh
sudo apt-get install -y unattended-upgrades && sudo dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl is-active unattended-upgrades
ls /var/run/reboot-required 2>/dev/null && cat /var/run/reboot-required.pkgs   # reboot when present
```

Reboot the web server in a quiet window; on the DB server the containers come
back by themselves (`restart: unless-stopped`), check with `verify` afterwards.
fail2ban (Ploi installs it) protects SSH: `sudo fail2ban-client status sshd`.

## Secrets on disk

| File | Should be |
|---|---|
| `/opt/db/.env` (DB passwords) | `600 root` |
| `/etc/docker-db-server-manager.conf` (no secrets) | `600 root` |
| `/opt/db/backups` | `700 root` |
| `/home/ploi/<site>-shared/.env` | `600 ploi` (the deploy script enforces it) |
| `<shared>/.env.bak.*` from `update-env-db.sh` | `600`; only the newest `KEEP_BACKUPS` (5) kept |
| `<shared>/install.env` | deleted after the first install (`shred`) |

Find stray copies: `find /home/ploi -maxdepth 3 -name '.env*' -printf '%m %p\n'`.

## Logs

| What | Where |
|---|---|
| Nightly DB backup | `/var/log/docker-db-server-backup.log` (logrotate weekly, 8 kept) |
| DB containers | `docker-db-server-manager.sh logs [postgres\|pgbouncer\|mysql\|mariadb]` |
| Deploys | Ploi → site → Deployments |
| Laravel | `<shared>/storage/logs/laravel.log` (or `<site>/storage/logs` on in-place sites) |
| Daemons | Ploi → server → Daemons → log, or `/home/ploi/.ploi/*.log` |
| nginx / PHP-FPM | `/var/log/nginx/`, `/var/log/php*-fpm.log` |
| SSH / fail2ban | `journalctl -u ssh`, `/var/log/fail2ban.log` |

## Monitoring (not built in)

This is ranked gap 3 in [status.md](status.md#monitoring).


Nothing here pages you. Cheap options: Ploi's server monitoring and email alerts,
DigitalOcean monitoring alerts (CPU, disk, memory), an uptime check on
`https://<site>/up` (UptimeRobot, Better Stack), and a cron that runs
`docker-db-server-manager.sh doctor` and mails on a non-zero exit, e.g.
`30 6 * * * root /root/docker-db-server-manager.sh doctor >/dev/null || echo "doctor failed on $(hostname)" | mail -s doctor you@example.com`.
