# Checklist: pre-launch

Before real users or paying customers. Each item links the page that explains it.

## Data

- [ ] prd is protected (`PROTECTED_ENVS` has `prd`) and `doctor` shows no PROBLEM lines.
- [ ] Off-site, encrypted backups on, key stored off the server ([backups](../backups-and-recovery.md)).
- [ ] PITR on for prd (`PITR=pgbackrest`) or prd on managed Postgres with PITR.
- [ ] A restore drill done this month ([drill](monthly-restore-drill.md)).
- [ ] Alerts reach a person (`doctor --alert` tested).

## Availability

- [ ] prd database decision recorded: managed + standby recommended ([ADR 0008](../adr/0008-database-topology.md)).
- [ ] Two web nodes behind a load balancer, or the single-node risk accepted in writing ([HA](../high-availability.md)).
- [ ] Sessions, cache and queues off the web nodes; uploads in object storage.
- [ ] Uptime monitor on `/up` every minute.
- [ ] Maintenance window set; `server update --reboot-window` scheduled.

## Security

- [ ] `server harden` applied on every host; password SSH off; root login by key only.
- [ ] DB ports listen on the private IP only (`doctor` "Exposure").
- [ ] TLS on the VPC (`TLS_MODE=require`), `verify-full` for managed prd.
- [ ] No superuser app logins, no `root@'%'` ([privileges](../reference/privileges.md)).
- [ ] `.env` files 600, `APP_DEBUG=false`, `env.sh check` clean.
- [ ] Platform tokens scoped and stored outside the repo ([credentials](../configuration.md)).

## Operations

- [ ] Inventory snapshots pulled for every host.
- [ ] Lockout recipe tested once on a scratch droplet ([recipe](../recipes/recover-ssh-lockout.md)).
- [ ] Runbook links shared with whoever is on call.
