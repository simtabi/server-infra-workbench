# 0013. Development and staging stay on 2 GB droplets with Postgres only

- Status: Accepted (amends the sizing in [0008](0008-database-topology.md))
- Date: 2026-10-31

## Context

[0008](0008-database-topology.md) put every environment on one hardened 4 GB DB server. The existing dev
and staging droplets are 2 GB. With all four engines on, the manager's estimate is 3392 MB
([Sizing](../reference/sizing.md)), so `doctor` warns and points at `do resize`. The apps use Postgres
only, so MySQL and MariaDB cost RAM and money without doing any work.

## Decision

- Non-production (tst, dev, stg) stays on 2 GB droplets with Postgres + PgBouncer only:
  `configure --profile dev-budget`, then `engine disable mysql` and `engine disable mariadb`.
- A resize to 4 GB is the fallback when Postgres alone is short of RAM (PITR on, real load), not the default.
- Production keeps the 0008 plan: its own server or managed Postgres before paying customers.

## Consequences

- About 1600 MB estimated use on a 2 GB node; PITR makes it tight (1728 MB), so swap stays on and
  `doctor` keeps warning below 90% of the estimate.
- `engine disable` takes a backup and keeps the data volume, so `engine enable <engine>` brings it back;
  enable warns first when the RAM estimate no longer fits.
- Monitoring on these nodes stays on the light stacks (ADR [0012](0012-monitoring-stack.md) RAM gate).
