#!/usr/bin/env bash
# Integration test for `upgrade` against throwaway containers (Docker/OrbStack on a
# workstation). Not part of `make ci` (needs Docker, ~3 min): run `make it`.
# Covers: install, dry run, happy path, idempotent re-run, forced verify failure ->
# auto-rollback, invalid config rejected, lock conflict, non-interactive fail-safe,
# secrets redacted in the log. Cleans up its containers and volumes.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/.."
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "upgrade-it skipped (no docker)"; exit 0; }
M="$PWD/scripts/db/docker-db-server-manager.sh"
W="$(mktemp -d /tmp/vsw-up.XXXX)"; D="$W/vswitdb"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true; rm -rf "$W"; }
trap cleanup EXIT
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$W/none.conf" \
  DBM_LOCK="$W/lock" DBM_LOG="$W/upgrade.log" BACKUP_DIR="$W/backups" MIN_FREE_MB=10 \
  ENABLE_MYSQL=0 ENABLE_ADMINER=0 PG_PORT=25432 PGBOUNCER_PORT=26432 MARIADB_PORT=23307 \
  PG_BASE_IMAGE=postgres:18 PG_IMAGE=vsw-test/postgres:18 PGVECTOR_PKG=postgresql-18-pgvector \
  PG_EXTENSIONS="vector pg_trgm citext" MARIADB_IMAGE=mariadb:11 PG_USER=app PG_DB=app PGBOUNCER_POOL_SIZE=20
# run a manager command like main does, but without the root check (workstation test)
run() { bash -c 'source <(sed "/^# ---- main/,\$d" "$1"); shift; need_root(){ :; }; check_engines; take_lock; "$@"' _ "$M" "$@"; }

run cmd_install > "$W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$W/install.out" && ok "install (old settings)" || { tail -30 "$W/install.out"; fail "install"; }

export PGBOUNCER_POOL_SIZE=25
run cmd_upgrade --dry-run > "$W/dry.out" 2>&1 && grep -q '^+PGBOUNCER_POOL_SIZE=25' "$W/dry.out" && grep -q 'dry run: nothing changed' "$W/dry.out" \
  && grep -q '^PGBOUNCER_POOL_SIZE=20' "$D/stack.env" && ok "dry run shows the diff and changes nothing" || { cat "$W/dry.out"; fail "dry run"; }

if run cmd_upgrade --non-interactive --yes </dev/null > "$W/ni.out" 2>&1; then fail "non-interactive without snapshot decision"; fi
grep -q 'no-snapshot' "$W/ni.out" && ok "non-interactive run fails safe without a snapshot decision" || { cat "$W/ni.out"; fail "ni"; }

if FORCE=0 run cmd_upgrade --no-snapshot </dev/null > "$W/noyes.out" 2>&1; then fail "apply without --yes"; fi
grep -q 'needs --yes' "$W/noyes.out" && grep -q '^PGBOUNCER_POOL_SIZE=20' "$D/stack.env" && ok "no tty + no --yes refuses to apply" || { cat "$W/noyes.out"; fail "noyes"; }

FORCE=1 run cmd_upgrade --no-snapshot </dev/null > "$W/up.out" 2>&1 && grep -q 'UPGRADE OK' "$W/up.out" && grep -q '^PGBOUNCER_POOL_SIZE=25' "$D/stack.env" \
  && grep -q 'backup verified' "$W/up.out" && ls "$D"/upgrade-saves/*/docker-compose.yml >/dev/null && ok "happy path: backup verified, savepoint, applied, verified" || { cat "$W/up.out"; fail "happy path"; }

FORCE=1 run cmd_upgrade --no-snapshot </dev/null > "$W/again.out" 2>&1 && grep -q 'already up to date' "$W/again.out" && ok "idempotent re-run: nothing to do" || { tail -20 "$W/again.out"; fail "idempotent"; }

export PGBOUNCER_POOL_SIZE=30
if DBM_TEST_FAIL_VERIFY=1 FORCE=1 run cmd_upgrade --no-snapshot </dev/null > "$W/rb.out" 2>&1; then fail "forced failure returned 0"; fi
grep -q 'ROLLBACK OK' "$W/rb.out" && grep -q 'UPGRADE FAILED and was rolled back' "$W/rb.out" && grep -q '^PGBOUNCER_POOL_SIZE=25' "$D/stack.env" \
  && (cd "$D" && docker compose --env-file .env --env-file stack.env ps --format '{{.Health}}' | grep -vq unhealthy) \
  && ok "forced verify failure -> auto-rollback to saved files, healthy again" || { tail -40 "$W/rb.out"; fail "rollback"; }
export PGBOUNCER_POOL_SIZE=25

if PRIVATE_IP=999.1.1.1 FORCE=1 run cmd_upgrade --no-snapshot > "$W/bad.out" 2>&1; then fail "bad ip accepted"; fi
grep -q 'not an IPv4' "$W/bad.out" && ok "invalid PRIVATE_IP rejected before any change" || { cat "$W/bad.out"; fail "bad ip"; }
if MARIADB_PORT=25432 FORCE=1 run cmd_upgrade --no-snapshot > "$W/dup.out" 2>&1; then fail "dup port accepted"; fi
grep -q 'used twice' "$W/dup.out" && ok "duplicate port rejected" || { cat "$W/dup.out"; fail "dup port"; }
if PGBOUNCER_IMAGE=edoburu/pgbouncer:latest FORCE=1 run cmd_upgrade --no-snapshot > "$W/lat.out" 2>&1; then fail ":latest accepted"; fi
grep -q 'pin a version' "$W/lat.out" && ok ":latest image rejected" || { cat "$W/lat.out"; fail "latest"; }

sleep 60 & holder=$!; mkdir "$DBM_LOCK"; echo "$holder" > "$DBM_LOCK/pid"
if FORCE=1 run cmd_upgrade --no-snapshot > "$W/lock.out" 2>&1; then fail "lock ignored"; fi
grep -q 'another run is in progress' "$W/lock.out" && ok "lock conflict refused" || { cat "$W/lock.out"; fail "lock"; }
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
FORCE=1 run cmd_upgrade --no-snapshot > "$W/stale.out" 2>&1 && grep -q 'stale lock' "$W/stale.out" && ok "stale lock recovered" || { cat "$W/stale.out"; fail "stale lock"; }

pw="$(grep '^PG_PASSWORD=' "$D/.env" | cut -d= -f2)"
[ -s "$DBM_LOG" ] && ! grep -qF "$pw" "$DBM_LOG" && [ "$(stat -c %a "$DBM_LOG" 2>/dev/null || stat -f %Lp "$DBM_LOG")" = 600 ] \
  && ok "log written, chmod 600, no secrets" || fail "log redaction"
echo "upgrade-it: all $pass checks passed"
