# Example: Laravel multi-tenant (tenant databases at runtime)

Made up: `shop` with a landlord database per environment (`shop_dev`, `shop_stg`) and one database per
tenant created by the app at runtime (`shop_dev_t_42`). DB droplet `10.0.0.5`, web `10.0.0.6`, VPC `10.0.0.0/20`.

**Why this layout:** a database per tenant gives hard isolation (backup, restore, delete one tenant) without
a second server. The app role may `CREATEDB` only in tenant environments (`TENANT_ENVS`); prd profiles turn
it off and use a migrator role instead ([database environments](../../docs/database-environments.md)).

```bash
examples/run.sh laravel-multitenant         # validate (offline)
bin/workbench configure --profile dev-budget --client <you> --set APP=shop --set 'TENANT_ENVS=dev stg' ...
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | profile + settings for `examples/run.sh` |
| [`tenant-connection.php`](tenant-connection.php) | a `config/database.php` connection for tenant DBs (no password in code) |

Checklist:

- [ ] Tenant DB names follow `<app>_<env>_t_<id>` so backups and `env_of_db` map them to their environment
- [ ] The app creates tenant DBs with the same login as the landlord (`DB_USERNAME`), password from `.env`
- [ ] Backups pick up new tenant DBs automatically (the manager lists databases at backup time)
- [ ] prd: `PG_APP_CREATEDB=0`; tenants are created by a deploy step with the migrator role

Lesson: a tenant created on `stg` with a prd-looking name ends up in the wrong backup set. Keep the env in the name.
