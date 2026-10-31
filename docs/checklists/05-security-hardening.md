# 05. Security hardening

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | SSH: keys only, root by key only | `bin/workbench server harden --host <alias> --dry-run`, then `--yes` | **in a second terminal** `ssh <alias> true` works before you close the first | `sshd -t` runs before reload; a bad drop-in is rolled back |
| 2 | fail2ban, unattended security updates, sysctl, journald cap | included in `harden` | `harden --check` exits 0 | baseline every server needs |
| 3 | Firewall | DB: `harden --firewall`; web: Ploi's Network tab; both: `bin/workbench do firewall-apply` | `bin/workbench do firewalls` no `WORLD-OPEN` | ufw doesn't stop Docker-published ports; the cloud firewall does |
| 4 | `ploi` out of the `docker` group (DB) | `bin/workbench server harden --host <db> --only dockergroup --fix-docker-group` (plan, then type yes); `doctor` warns until it is done | `id ploi` without `docker` | `docker` group = root without a password |
| 5 | No superuser app login, no `root@'%'` | `M upgrade` (1.4.0+) | `M doctor` MySQL/MariaDB + Postgres sections ok | [lessons](../lessons-learned.md#databases) |
| 6 | TLS for DB connections | `TLS_MODE=require`; `M upgrade` | `M doctor` "TLS on"; app `DB_SSLMODE=require` | the VPC is shared infrastructure; prd needs it |
| 7 | `.env` files 600, debug off | `bin/workbench env check --env prd --site <domain>` | no FAIL | `.env` holds every secret |
| 8 | Platform tokens scoped, outside the repo | `bin/workbench credentials` | values never printed; file 600 | [ADR 0005](../adr/0005-credentials-outside-the-repo.md) |
| 9 | Keys reviewed | `bin/workbench keys account list --provider digitalocean`; `keys server list --host <alias>` | only current people and machines | old laptops keep working keys forever |
| 10 | Client data out of the repo | `make client-check` | `0 hits` | the repo is public; client setups live in `local/` |
