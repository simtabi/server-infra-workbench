# Example: web + DB on one droplet (dev only)

Made up: one 4 GB droplet `lab-01` (private `10.0.0.5`) running Ploi's PHP and Nginx *and* the DB manager's Docker
stack (Postgres + PgBouncer), environment `dev` of app `lab`, VPC `10.0.0.0/20`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf) with `ENVS=dev` and both private IPs the same.

**Why (and why only for `dev`):**

- **One bill, and the same commands as the split layout.** The app still connects to `10.0.0.5:6432` (PgBouncer), the
  private IP, not `localhost`. Splitting later is a `pg_dump`/`restore` to a new DB droplet and one `DB_HOST`
  change. The settings, the `.env` and the DB manager are the same as in
  [split-web-db-vpc](../split-web-db-vpc/README.md).
- **Not for `stg` or `prd`.** One droplet is one failure domain. A runaway `npm run build` or a PHP worker
  leak takes RAM from Postgres and the OOM killer picks the biggest process, usually Postgres. So
  `ENVS=dev`, with nothing protected and no tenant databases.
- **4 GB, because both estimates land on the same RAM.** With `SINGLE_DROPLET=1` (or both private IPs
  equal) `configure` checks one `db+web` node of `DB_DROPLET_MB`, the OS counted once:

  | Runs there | `configure` estimate (MB) |
  |---|---|
  | OS | 512 |
  | Postgres, PgBouncer | 1088 |
  | PHP-FPM, Nginx, workers | 1024 |
  | together | ~2624 of 4096 |

  That leaves about 1.4 GB for `composer`/`npm` during a deploy. On 2 GB `configure` refuses it; swap is a
  safety net, not capacity. Add-ons and monitoring placed on `web` or `db` are added to the same node.
- **Ploi without its own database.** Create the Ploi server with *no* database (no MySQL/Postgres from Ploi),
  or Ploi's Postgres takes port 5432 before the manager's container can bind it.
- **The DB bound to the private IP, never `0.0.0.0`.** Docker's published ports bypass `ufw`. The manager
  binds `PRIVATE_IP`, so Postgres isn't reachable from the internet whatever the host firewall says. The DO
  cloud firewall (in front of the droplet) is the second layer.

```bash
examples/run.sh single-droplet-all-in-one      # validate (offline): profile checks with both roles on one IP
bin/workbench configure --profile dev-budget --client <you> --set APP=lab --set ENVS=dev --set TENANT_ENVS= \
  --set PROTECTED_ENVS= --set SINGLE_DROPLET=1 --set DB_DROPLET_MB=4096 --set WEB_DROPLET_MB=4096 \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.5 --set VPC_CIDR=10.0.0.0/20
# after Ploi provisioned the server (no database): swap + Docker only; Ploi owns ufw, nginx, PHP and SSH
bin/workbench server init --host lab-01 --role db --only swap,docker
bin/workbench do firewall-apply web --vpc 10.0.0.0/20 --droplet <droplet-id> --dry-run
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh single-droplet-all-in-one`: settings through `configure --dry-run` |

Checklist:

- [ ] `ss -ltn` shows `10.0.0.5:5432` and `10.0.0.5:6432`, nothing on `0.0.0.0:5432`
- [ ] `free -m` after a deploy: available memory stays above ~500 MB; `swapon --show` lists `/swapfile`
- [ ] the off-site backup bucket is set (`OFFSITE_BUCKET`): a dev droplet still holds a day of someone's work
- [ ] PHP-FPM `pm.max_children` sized for what's left (Ploi -> Server -> PHP), not for a whole 4 GB box

Lesson: when this droplet starts swapping during deploys, that's the signal to split, not to resize. A
bigger box only moves the point where the build and the database fight over memory.
