# Checklist: new web server (Ploi)

1. [ ] Server created in Ploi in the DB server's VPC; private IP noted and added to the DB's `ALLOW_<env>`
       (`env-init --allow <env>=<ip>/32`, then `env-apply`).
2. [ ] `bin/workbench server init --host <web> --role web --dry-run`, then `--yes` (no Docker or ufw under Ploi).
3. [ ] `bin/workbench server harden --host <web> --dry-run`; Ploi keeps its own firewall.
4. [ ] Site created; deploy script from [deploy-script](../tools/deploy-script.md).
5. [ ] Shared `.env` on the web server: `env.sh init --env <env> --site <domain> --from <env>-db.env
       --url https://<domain> --dry-run`, then without `--dry-run` ([Laravel .env](../tools/env.md)). Later DB changes:
       `update-env-db.sh --remote <web> --site <domain> --from <env>-db.env` from the workstation.
6. [ ] `src/shell/web/check-db-reach.sh` reaches the DB on the private IP only.
7. [ ] `env.sh check --env <env> --site <domain>` passes; `APP_DEBUG=false` outside dev.
8. [ ] Queue worker and scheduler ([run daemons](../recipes/run-daemons.md)).
9. [ ] First deploy; `/up` returns 200; `bin/workbench web diagnose --host <web> --site <domain> --env <env>` is clean.
10. [ ] Uptime check on `https://<domain>/up`.
11. [ ] `bin/workbench server inventory --host <web> --pull --client <client>`.
