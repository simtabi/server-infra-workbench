# Plan: Postgres "syntax error at or near \"\\\"" log errors (2026-10-31)

Status: diagnosed, fixed in the toolkit (2026-11). Owner: workbench maintainers.
Found during the [live rollout rehearsal](../rehearsals/2026-11-live-rollout.md): the snapshot clone's Postgres log
had errors from the day before; a read-only look at the production log confirmed the same lines there.

## What the log shows

Five errors, all from one connection burst lasting under half a second, and none before or since
(the container log covers several days, and PgBouncer shows no errors):

```text
ERROR:  syntax error at or near "\" at character 65
STATEMENT:  select datname from pg_database where datallowconn and datname<>\x27template1\x27
```

The other four have the same shape: read-only catalog queries (`pg_settings`, `pg_roles`, `pg_database`,
`pg_available_extensions`) where every single quote arrived as the four characters `\x27`.

## Root cause

`\x27` is the hex escape for `'`. Some tools expand it (`printf`, `echo -e`, bash `$'...'`, awk, perl); a
plain shell string does not. The burst was an ad-hoc audit sent as
`ssh <db-host> 'docker exec ... psql -c "... \x27template1\x27 ..."'`: the author used `\x27` to dodge
the outer single quotes, but inside double quotes bash keeps it literally, so psql received `\x27...` and
Postgres stopped at the backslash.

It was **not** the application (Laravel uses bound parameters and the statements are catalog audits, not app
tables), **not** cron/backups/monitoring (they run on a schedule; this was a single burst), and **not** a
toolkit command: no script in the repo sends `\x27` to SQL (now enforced by a test). The toolkit's own SQL uses
`sql_lit` for literals and validated names for identifiers.

## Impact

None on data. Every statement was rejected while parsing, so nothing ran and nothing changed. The errors are
log noise, but noise hides real problems: a doctor that ignores the log would also ignore a failing login loop
or a permissions error after a migration.

## Fix

1. **Know about log errors without reading the log**
   - New manager command `log-errors [--since 24h|7d|all] [--service postgres|pgbouncer]`: read-only.
     It groups ERROR/FATAL/PANIC lines, classifies them (shell-quoting, auth, privilege, missing-object,
     sql-syntax, concurrency, resource), and masks string literals, passwords and IPs. Exit 1 when errors
     are found.
   - `doctor` gains a warning when Postgres logged errors in the last 24 h, so the nightly `doctor --alert`
     cron surfaces them.
   - Workstation checker `bin/siwo db pg-log-errors --host <db-alias>` reads the log over ssh with
     `docker logs` and prints the same summary. It installs nothing, needs no sudo when the login user is in
     the docker group, and works before the manager upgrade.
2. **Stop it recurring**
   - A regression test fails if any toolkit script puts a literal `\x27` next to SQL.
   - Ad-hoc SQL over ssh: never escape quotes by hand. Send the SQL on stdin from a quoted heredoc, and pass
     values as psql variables (`:'name'` for a literal, `:"name"` for an identifier), or use `format()` with
     `%L`/`%I` inside SQL:

```bash
ssh <db-host> 'docker exec -i db-postgres-1 psql -U <admin> -d postgres -tA -v skip=template1' <<'SQL'
select datname from pg_database where datallowconn and datname <> :'skip';
SQL
```

   Prefer the manager's read-only commands (`doctor`, `list-dbs`, `list-users`, `env`) over hand-written
   audit queries.

## Repair

Nothing to repair: no statement ran. The verification is read-only:

```bash
bin/siwo db pg-log-errors --host <db-alias> --since 7d    # before or after the upgrade
sudo /root/docker-db-server-manager.sh log-errors --since 7d   # on the server, after the upgrade
sudo /root/docker-db-server-manager.sh doctor                  # privilege model, settings, backups
```

The Oct 31 burst keeps showing until the postgres container's log rotates or the container is recreated
(the next `upgrade` does that). Log time is UTC.

## Acceptance

- `log-errors` on a clean log prints "no errors" and exits 0. On the production log it reports the single
  shell-quoting group (5x), with literals masked.
- `doctor` shows `warn postgres log: ...` while the burst is inside the last 24 h, then `ok`.
- `tests/shell/smoke-db.sh` covers grouping, classification, masking, `--since`, the doctor warning and the
  `\x27` regression rule.
