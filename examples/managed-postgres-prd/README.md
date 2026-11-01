# Example: production on a managed Postgres

Made up: app `shop`, prd on a DigitalOcean Managed Postgres cluster with a standby, two Ploi web nodes
behind a load balancer, files on Spaces, a dedicated monitoring node, VPC `10.0.0.0/20`. Profile
[`production-ha`](../../config/profiles/production-ha.conf).

**Why:** one DB droplet and one web droplet are single points of failure. A managed cluster with a standby
takes over failover, backups and PITR for prd; two web nodes keep the site up through a node failure, so they
must not keep files locally ([ADR 0008](../../docs/adr/0008-database-topology.md),
[high availability](../../docs/high-availability.md)).

```bash
examples/run.sh managed-postgres-prd     # validate (offline): managed prd, alerts, monitoring hub
bin/workbench configure --profile production-ha --client <you> --set APP=shop \
  --set ALERT_EMAIL=<you@example.com> --set VPC_CIDR=10.0.0.0/20
```

Most of this profile is documented, not automated: the cluster, the load balancer and the trusted sources are
created in the DO control panel. Moving existing data: [migrate to managed](../../docs/recipes/migrate-to-managed.md).

Checklist:

- [ ] Cluster, web nodes and DB server in the same region and VPC; web nodes added as trusted sources
- [ ] `migrate-managed` rehearsed, then the final sync in a maintenance window
- [ ] Monitoring on its own node, so it survives a web node failure

Lesson: a load balancer in front of web nodes that write uploads to local disk serves missing files half the
time. Files go to Spaces first.
