# Plan: P1 and P2 implementation

Status: approved, implemented (2026-10; the WireGuard container test followed in P3, `wg-it`). Owner: workbench maintainers. Supersedes the "Proposed: not built yet"
rows of [status](../status.md#proposed-not-built-yet) that are listed below.

This plan says **what** we build, **why**, **how** (design), what can go wrong (**risks**) and how we know it
is done (**acceptance**). Each phase lands as its own commits, so a half-finished plan never leaves `main`
broken. Nothing here changes a live server: every command ships with a dry run, a plan, a confirmation and a
runbook row that a human runs.

## Principles that apply to every phase

| Principle | What it means here | Why |
|---|---|---|
| Plan, confirm, apply, verify | every mutating command prints a plan, asks (typed word on protected envs), then checks its own result | a tool that can't show what it will do can't be trusted on prd |
| Loopback or private only | new listeners bind `127.0.0.1`, a private (VPC/WireGuard) IP, or nothing; public needs an explicit flag + auth + TLS | Docker-published ports bypass ufw |
| Pinned images | every image has a version tag, `:latest` is refused | an unpinned image changes under you on the next pull |
| Secrets in 600 files | generated on the server, never on argv, never printed, never logged (log redaction stays) | shell history, `ps` and logs leak argv |
| Config, not code | features are switched by keys (`MONITOR_STACKS`, `TLS_MODE`, ...) validated by the configurator and the tool | one code path, many setups |
| Client-free repo | real hosts, IPs, regions and names live in the gitignored `local/` | the repo is public |
| Tested | offline smoke tests for logic, container tests (`make it`) for anything that talks to Docker | the integration tests caught every real bug so far |

## Phases

### Phase 1 (P1): finish what the checklists already promise

| # | Item | Design | Acceptance |
|---|---|---|---|
| 1.1 | Docker group check | `server harden` gets a `dockergroup` item: members of `docker` other than root are reported (warn); `--fix-docker-group` turns it into a change (`gpasswd -d`, confirmed like every other item). `DOCKER_GROUP_ALLOW=user,...` exempts intended users. The DB manager `doctor` warns too. | smoke test: report, allow-list, fix on a sysroot; checklist 05 row 4 matches |
| 1.2 | Region in the generated dev-budget config | the profile keeps the region a prompt/default only (no client region in the repo); the client's file in `local/` says `nyc1` | `rg nyc3 local/` shows only the Spaces endpoint |
| 1.3 | Live runbook | [runbooks/live-rollout.md](../runbooks/live-rollout.md): the 11 never-run live tasks in order, copy-paste, with verify and rollback per step, placeholders only | links check passes; every command exists (`--help`) |

### Phase 2 (P2): features

#### 2.1 Progress UX (shell, PHP, Python)

- **Design.** One contract, three implementations: `spinner` (unknown length), `bar` (known total, with ETA),
  `step` (`[3/9] label ... 12s`). TTY-aware: on a terminal it redraws one line; otherwise (CI, cron, a pipe,
  `TERM=dumb`) it prints one plain line per start/finish, never control codes. `NO_COLOR` disables colour,
  `--quiet`/`SIW_QUIET=1` silences progress (errors still print). Output goes to stderr so stdout stays
  parseable.
- **Shell:** `src/shell/lib/progress.sh` (`progress_step`, `progress_run "label" cmd...`, `progress_bar i n`,
  `progress_done`). The DB manager is a single uploaded file, so it carries a copy between
  `# >>> progress.sh` markers; a smoke test fails when the copy drifts from the library (DRY by test).
- **PHP:** `Console\Progress` (spinner/bar/ETA, same rules) used by the action waits (snapshot, resize, power).
- **Python:** `server_infra_workbench.progress` used by the plan finder and the configurator.
- **Wired into:** manager `upgrade` (numbered steps), `backup` (per engine), `offsite` (upload/verify),
  `restore-test`, PITR, the DO resize/snapshot waits, and `make it` (per suite, ETA from the last run).
- **Risk:** control codes in logs. Mitigation: the manager logs through `tee`; progress writes to the
  terminal (fd 3 when present) only, and plain lines everywhere else.
- **Acceptance:** non-TTY output has no `\r`/ESC (test), `NO_COLOR` honoured (test), library copy in sync (test).

#### 2.2 Monitoring add-on: `workbench monitor`

- **Stacks** (any combination, `MONITOR_STACKS=beszel,kuma,netdata,prometheus` or `none`):

  | Stack | What it is | RAM (est.) | Default |
  |---|---|---|---|
  | `beszel` | hub (one node) + agent (every node): host, containers, disk, alerts | hub 64 MB, agent 32 MB | yes |
  | `kuma` | Uptime Kuma: HTTP/TCP/cert/push monitors, status page, notifications | 192 MB | yes |
  | `netdata` | per-node real-time metrics, zero config | 256 MB | no |
  | `prometheus` | Prometheus + Alertmanager + Grafana + node-exporter + cAdvisor + postgres-exporter + pgbouncer-exporter + blackbox (certs/HTTP) | ~600 MB hub, ~120 MB per node | no |

- **Roles:** `hub` (runs the UIs and the collectors) and `agent` (exporters/agents only). One hub monitors both
  servers across regions over the VPC or the WireGuard tunnel (`MONITOR_TARGETS`).
- **Exposure:** UIs on `127.0.0.1` only (SSH tunnel; `monitor tunnel` prints the command). Agents/exporters bind
  the private or WireGuard IP (validated private), never `0.0.0.0`. Optional `MONITOR_PUBLIC=1` adds a Caddy
  front with basic auth + automatic HTTPS, refused on a Ploi server (nginx owns 80/443).
- **What is watched:** host CPU/RAM/disk/network, every container (cAdvisor/Beszel), images, Postgres and
  PgBouncer, backup freshness + off-site + restore tests (the manager writes node-exporter textfile metrics),
  certificate expiry (blackbox), both servers.
- **Grafana:** provisioned datasource and dashboards (overview, containers, Postgres/PgBouncer, backups and
  certificates); alert rules in Prometheus (Alertmanager → email/webhook).
- **Validation:** the configurator rejects unknown stacks, checks placement (hub on one node) and RAM: on a
  2 GB node, `prometheus` or `netdata` next to the database is **blocked** unless `MONITOR_ALLOW_TIGHT=1`;
  Beszel and Kuma only warn. The tool repeats the check against `/proc/meminfo`.
- **`workbench status`:** a quick health table for one or more hosts over ssh (load, RAM, disk, containers,
  unhealthy, reboot needed, last backup, monitor stacks) plus optional URLs, `--json` for scripts.
- **Docs:** guide, [ADR 0012](../adr/0012-monitoring-stack.md) (why Beszel + Kuma is the default), checklist.
- **Risk:** monitoring itself exhausting RAM on 2 GB droplets → RAM gates; exporters exposing data → private
  binds + VPC firewall; default credentials → generated, 600 files.
- **Acceptance:** container test brings up each stack, checks loopback/private binds, health, Prometheus targets
  up, Grafana datasource + dashboards provisioned, rules loaded, Beszel system registered.

#### 2.3 Major Postgres upgrade

- **Design:** `pg-major-upgrade --to <major> [--dry-run] | --cleanup <old>`: dump/reload in the **same volume**.
  The 18+ images keep data in `/var/lib/postgresql/<major>/docker`, so the new major gets its own directory;
  the old one is renamed to `.pg<old>-old` (the new entrypoint refuses to init while `<old>/docker` exists) and
  kept for rollback until `--cleanup`. Steps: plan (images, pgvector package, disk) → verified backup →
  `pg_dumpall` → stop → set old data aside → build the new image → init + reload → converge roles/extensions →
  inventory compare → verify → PITR stanza-upgrade. Any failure puts the old data, image and config back.
  `pg_upgrade` is not used: postgis/pgvector binaries must exist for both majors in one image, which the
  upstream images don't provide. Recipe: [pg-major-upgrade](../recipes/pg-major-upgrade.md).
- **Acceptance:** `make it` upgrades an 18 server with data to 19 (the 19 release candidate), row counts equal,
  verify-full through PgBouncer works after; forced-failure rollback tested; `--cleanup` tested.

#### 2.4 verify-full TLS

- **Design:** `TLS_MODE=verify-full` = `require` + a CA that clients pin. The CA key stays on the DB server
  (`$DB_DIR/tls/ca.key`, 600); `tls-ca` prints only the CA certificate (public) for the web hosts; `env` prints
  `DB_SSLMODE=verify-full` and `DB_SSLROOTCERT`. PgBouncer gets `client_tls_*` and `server_tls_sslmode`.
  Certificates are reissued when a bind IP is missing from the SAN or within 30 days of expiry.
- **Acceptance:** container test connects with `sslmode=verify-full` to Postgres and PgBouncer and fails with a
  wrong CA.

#### 2.5 Migration to managed Postgres (prd)

- **Design:** `migrate-managed --target-env FILE [--db NAME] [--dry-run]`. Target credentials come from a 600
  file (never argv). `pg_dump -Fc` per database → `pg_restore --no-owner --no-acl` into the target with
  `sslmode=require` (or `verify-full` + CA) → per-table row counts compared → cutover checklist printed. Read-only
  on the source.
- **Acceptance:** container test migrates into a second Postgres acting as the managed target; counts match.

#### 2.6 Tests

PITR restore end to end (posix repo), MySQL 9.7 in `make it`, a two-host WireGuard tunnel between two privileged
containers, monitoring stacks, `pg-major-upgrade`, `verify-full`, `migrate-managed`.

- **Done:** `pitr-it` (posix repo, restore to a timestamp, prd guard), `db-features-it` (MySQL 9.7, 18 to 19
  upgrade with grants kept, `verify-full` through PgBouncer, `migrate-managed`, `--cleanup`), `monitor-it`
  (27 checks: exporters as `vsw_monitor`, rules, Grafana auth, Beszel self-registration, probes, remove).
- **Deferred:** the two-host WireGuard test. It needs privileged containers and the `wireguard` kernel module,
  which Docker Desktop and most CI runners lack ([status](../status.md#not-tested)). Done later in P3: `wg-it`
  runs kernel WireGuard with `NET_ADMIN` only.
- **Found by the tests:** `cmd | grep -q` under `pipefail` turned matches into misses (Beszel never
  self-registered); a zero `grep -o | wc` count ended `monitor doctor`; file_sd missed host-side renames.

#### 2.7 `env init` merges add-on keys

`env init --addons` (or `ENV_ADDONS=auto`) merges every `laravel-env` file the add-ons wrote on that host
(`/opt/vsw-addons/*/laravel.env`), masked in the output, 600 on disk. Only 600/400 files are read; an explicit `--set` wins; an empty
add-on value (RustFS's key placeholder) never clears a value you already have.

#### 2.8 Retag the client-named Postgres image

`upgrade` already retires a custom `PG_IMAGE` tag when the configured tag changes. Doc:
[recipes/retag-postgres-image.md](../recipes/retag-postgres-image.md); the client file in `local/` drops its
custom tag so the next upgrade does it.

## Order and milestones

1. Plan (this file). 2. P1. 3. Progress libraries + wiring. 4. Monitor add-on + status. 5. Manager: TLS,
major upgrade, managed migration, monitoring user + metrics. 6. env merge, retag doc. 7. Container tests.
8. Docs, status, ADRs, lessons learned. 9. `make ci`, `make it`, gitleaks, client scans, self-audit, push.

## Out of scope (P3, stays in [status](../status.md))

HA (second web node, standby), platform API gaps (DO VPC peering, trusted sources, Spaces keys), Dependabot for
the Caddy stack, GitHub Actions billing.
