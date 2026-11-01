# 08. Deploys

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | `.env` complete for this release | `bin/workbench env check --host <web> --env <env> --site <domain>` | no missing keys | a new key missing in prd is a classic 500 |
| 2 | Backup before risky migrations (prd) | `M backup` | `M offsite verify` | destructive migrations need a way back |
| 3 | Deploy | `bin/workbench ploi deploy <server-id> <site-id>` | Ploi deploy log ends in success | the script runs migrations with `--force` and swaps releases atomically |
| 4 | Health | `bin/workbench health https://<domain>/up` | 200 within a few seconds | the same endpoint the uptime check uses |
| 5 | Diagnose | `bin/workbench web diagnose --host <web> --site <domain> --env <env>` | exit 0 | migrations pending, storage permissions, daemons, logs |
| 6 | Queue workers restarted | the deploy script runs `queue:restart` (zero-downtime: the post-deploy script, `STAGE="post"`) | `ploi daemons <server-id>` running | old workers run old code |
| 7 | Roll back if needed | Ploi: redeploy the previous commit; DB: `M restore` only with a backup from step 2 | `/up` 200 | code rolls back in seconds, data doesn't |
