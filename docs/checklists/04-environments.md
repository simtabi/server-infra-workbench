# 04. Environments (tst, dev, trn, stg, prd)

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Decide the layout | [database environments](../database-environments.md), [ADR 0008](../adr/0008-database-topology.md) | the decision is in `local/<client>/` | one server for non-prod, prd moves to managed before launch |
| 2 | Run the wizard | `M env-init --dry-run`, then `M env-init --out /etc/docker-db-server-manager.conf` | `APP`, `ENVS`, `TENANT_ENVS`, `PROTECTED_ENVS` in the config | the script always asks: app, engines, envs, tenants, protection, backups, TLS |
| 3 | Create databases and users | `M env-apply` | `M env-list` shows `<app>_<env>` with `_app` and `_ro` per env | each env has its own database and login, so a stg bug can't touch prd |
| 4 | Privileges match the model | `M doctor` | Isolation section ok | [privileges](../reference/privileges.md): no superuser, tenants only where enabled |
| 5 | Credentials per env | `M env-creds <env> --out /root/<env>-db.env` | file 600, one per env | each web `.env` gets only its own env's password |
| 6 | Web `.env` per env | `bin/siwo env init --env <env> ...` ([03](03-web-setup.md) step 6) | `env check` clean; `APP_ENV` matches | `APP_DEBUG=false` outside dev |
| 7 | Prove prd is protected | `M drop-db <app>_prd` (expect a refusal) | refuses without `--force-prod` and the typed name | the guard rail must work before you need it |
| 8 | Read-only access for people | `M create-user <name>_ro <app>_<env> --readonly --out /root/<name>.creds` | `M list-users` shows SELECT only | humans read with a read-only login |
