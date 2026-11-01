# Example: three engines during a migration

Made up: app `shop` moving from MariaDB to Postgres, DB droplet `db-01` (`10.0.0.5`, 4 GB), web droplet
`web-01` (`10.0.0.6`), VPC `10.0.0.0/20`, environments `dev` and `stg`. Profile
[`multi-engine`](../../config/profiles/multi-engine.conf).

**Why:** during a move the old and the new engine both have to run, with the same backups and users, so the
app can switch per environment and back. The profile sizes the droplet for all three engines (about 3.4 GB,
estimate) and `configure` refuses a droplet too small for them.

```bash
examples/run.sh multi-engine-migration   # validate (offline): RAM for three engines, ranges, off-site
bin/workbench configure --profile multi-engine --client <you> --set APP=shop \
  --set ALERT_EMAIL=<you@example.com> --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
```

Checklist:

- [ ] Each environment switched and verified before the next one
- [ ] The old engine turned off once nothing uses it: `engine disable` in the
      [DB manager](../../docs/tools/db-server-manager.md) (the data volume is kept until you delete it)
- [ ] Droplet resized down afterwards if the RAM is no longer needed ([sizing](../../docs/reference/sizing.md))

Lesson: a "temporary" second engine tends to stay. Put the `engine disable` date in the migration plan.
