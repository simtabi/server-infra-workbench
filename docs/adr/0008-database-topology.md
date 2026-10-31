# 0008. Database topology: one hardened server now, managed prd before launch

- Status: Accepted, sizing amended by [0013](0013-dev-on-2gb-postgres-only.md)
- Date: 2026-10-31

## Context

An app needs up to five environments (tst, dev, trn, stg, prd). The options compared in
[Database environments](../database-environments.md#topologies) range from one shared server (~$29/month,
estimate) to self-hosted Patroni HA ($100+ and ongoing operator time). The team is one person, there is no
customer data yet, and the old server (1.9 GB) was too small for four engines.

## Decision

- **Now:** topology A, every environment on one hardened 4 GB DB server, with one database and its own
  roles per environment, protected stg and prd, off-site encrypted backups and PITR.
- **Before paying customers:** topology C, prd on DigitalOcean Managed Postgres with one standby; non-prod stays
  self-hosted. The manager supports this with `PRD_LOCATION=managed` and `env-sql prd`.
- **Web tier:** two web nodes behind a load balancer before launch ([HA](../high-availability.md)).
- Self-hosted HA (topology D) only if managed Postgres turns out too limiting. Per-env containers (E) are not
  supported.
- Turn on only the engines the app uses; Postgres is the default.

## Consequences

- One code path (one Postgres, many databases) to test and document; the same contract carries over to a
  separate prd host.
- Until prd moves, a host failure takes every environment down; RPO is about a minute with PITR, RTO
  15-45 minutes (estimates).
- Managed prd means no superuser, so the manager prints SQL for an admin instead of connecting.
