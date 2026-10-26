# Architecture

Two (or more) DigitalOcean droplets in the same region and VPC, managed with
[Ploi](https://ploi.io). The reference deployment runs in Atlanta (`atl1`).

```
                 internet
                    │ 80/443
          ┌─────────▼─────────┐        DO VPC (e.g. 10.0.0.0/20)        ┌──────────────────────────┐
          │  web server       │ ────────────────────────────────────────▶ │  db server               │
          │  Ploi site        │   DB_HOST = db private IP (eth1)          │  /opt/db docker compose  │
          │  native PHP or    │                                           │  :5432 postgres+postgis  │
          │  Ploi "Docker"    │                                           │  :6432 pgbouncer         │
          │  server type      │                                           │  :3306 mysql :3307 maria │
          └───────────────────┘                                           └──────────────────────────┘
```

- **Web server**: a Ploi server, either native (nginx + PHP-FPM, deployed with
  [`ploi-deploy.sh`](deploy.md)) or Ploi's Docker server type (see
  [web-server-ploi.md](web-server-ploi.md#ploi-docker-servers) and the
  [Caddy example](../compose/caddy)).
- **DB server**: a plain droplet (provisioned through Ploi so it gets the
  `ploi` user), running the Docker stack from
  [`docker-db-server-manager.sh`](db-server.md). Every DB port is bound to the
  **private** IP only, and ufw allows only the VPC range.
- **Network**: on a DO droplet
  - `eth0` = public IP **plus** a `10.10.x.x` "anchor" IP. The anchor IP is
    normal (it shows in the login banner) and is *not* the VPC address.
  - `eth1` = the VPC private IP. Find it with `ip -4 -o addr show eth1`.
    That is what `DB_HOST` and `PRIVATE_IP` must be.
- **Access**: per-host ed25519 keys managed by sshmgr, user `ploi`, `sudo` with
  the password from Ploi's provisioning email. See [ssh-access.md](ssh-access.md).

## Where things live

| What | Where |
|---|---|
| DB stack, generated `.env` with passwords | db: `/opt/db` (`.env` chmod 600) |
| DB backups | db: `/opt/db/backups/<YYYYmmdd-HHMMSS>/` (daily 03:15 server time, keep 7) |
| Manager script / config | db: `/root/docker-db-server-manager.sh`, `/etc/docker-db-server-manager.conf` |
| Laravel releases | web: `/home/ploi/<site>/` (Ploi zero-downtime) |
| Shared `.env` and `storage/` | web: `/home/ploi/<site>-shared/` |
