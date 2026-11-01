# Sizing (RAM estimates)

The numbers the DB manager (`engine_ram_mb`, used by `doctor` and `engine enable`) and the
configurator profiles use to decide whether a droplet is big enough. They are **planning estimates, not
measurements**: a busy database wants more, an idle dev one gets by with less. Measure with `docker stats`
and `free -m` once real traffic arrives.

| Component | RAM (MB, estimate) | Notes |
|---|---|---|
| OS + Docker | 512 | Ubuntu 24.04 or 26.04 LTS, dockerd, containerd, journald |
| PostgreSQL 18 | 1024 | `shared_buffers` ~25% of this; more for big indexes |
| PgBouncer | 64 | |
| MySQL 9.7 | 1024 | InnoDB buffer pool is the main cost |
| MariaDB | 768 | |
| Adminer | 64 | loopback only, off by default |
| pgBackRest (PITR on) | 128 | archive-push and backups |

| Engines on | Total (estimate) | Smallest DO basic size (`size_for_mb`) |
|---|---|---|
| Postgres + PgBouncer | 1600 MB | `s-1vcpu-2gb` (2 GB) |
| Postgres + PgBouncer + PITR | 1728 MB | `s-1vcpu-2gb`, tight; `s-2vcpu-4gb` recommended |
| Postgres + PgBouncer + MySQL | 2624 MB | `s-2vcpu-4gb` (4 GB) |
| All four engines | 3392 MB | `s-2vcpu-4gb`, no headroom; 8 GB for real load |

`doctor` and `engine enable` warn when the host has less than 90% of the estimate and print the
`bin/siwo do resize <droplet> --size ...` command for the smallest size that fits (or suggest
`engine disable mysql`). Each extra environment on the
same server adds databases, not processes, so it costs disk and cache rather than a fixed amount of RAM.

Prices for these sizes are in [Database environments](../database-environments.md#topologies) (estimates
from DigitalOcean list prices, Oct 2026). Swap (`server init --swap 2G`) is a safety net, not capacity.
