# 03. Web setup (Ploi)

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Web server in the DB's region and VPC | Ploi: create server; `bin/siwo do droplets` | same REGION, private IP in the VPC | cross-region private traffic doesn't route ([cross-region](../cross-region.md)) |
| 2 | Allow it on the DB | DB config `ALLOW_<env>=<web-private-ip>/32`, then `M env-apply` | `M doctor` Isolation ok | each env's roles accept logins only from its own allow list |
| 3 | Init and harden | `bin/siwo server init --host <web> --role web --dry-run`, then `--yes` | re-run shows `ok` | no Docker or ufw changes under Ploi (Ploi owns ufw) |
| 4 | Site and deploy script | `bin/siwo ploi site-create <server-id> <domain> --dry-run`; `ploi deploy-script-set ... --file ...` | `bin/siwo ploi sites <server-id>` | the generic deploy script is zero-downtime ([deploy script](../tools/deploy-script.md)) |
| 5 | DB credentials file | `M env-creds <env> --out /root/<env>-db.env` | file is 600 on the DB server | passwords travel as a file, never on a command line |
| 6 | Laravel `.env` from the template | `bin/siwo env init --host <web> --env <env> --site <domain> --from <env>-db.env --url https://<domain> --dry-run`, then without | `bin/siwo env check --host <web> --env <env> --site <domain>` | every key we need, APP_KEY generated, 600, values never printed |
| 7 | Right host and port | `.env`: `DB_HOST=<db-private-ip>`, `DB_PORT=6432` (PgBouncer) | `bin/siwo web check-db-reach --remote <web> <db-private-ip> 6432 5432` | public IP or 5432-vs-6432 mix-ups were real outages |
| 8 | Daemons | `bin/siwo ploi daemon-create <server-id> --command "php artisan queue:work" --directory <dir> --dry-run` | `ploi daemons <server-id>` | queues and the scheduler don't run themselves ([run daemons](../recipes/run-daemons.md)) |
| 9 | First deploy | `bin/siwo ploi deploy <server-id> <site-id>` | `bin/siwo health https://<domain>/up` is 200 | migrations run in the deploy; an empty DB means they didn't |
| 10 | Diagnose clean | `bin/siwo web diagnose --host <web> --site <domain> --env <env>` | exit 0, no FAIL | catches `.env`, storage, DB, migrations and daemons in one pass |
| 11 | Add-ons (optional) | on the server: `addon.sh plan gotenberg --role web`, then `install ... --yes` | `addon.sh doctor gotenberg` | Gotenberg on the web node binds 127.0.0.1; object storage belongs elsewhere ([add-ons](../tools/addons.md)) |
| 12 | Inventory | `bin/siwo server inventory --host <web> --pull --client <client>` | files pulled | baseline |
