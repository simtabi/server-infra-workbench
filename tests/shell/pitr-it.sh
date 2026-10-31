#!/usr/bin/env bash
# Integration test of point-in-time recovery (`make it`): PITR=pgbackrest with a posix repo
# in a throwaway stack. setup (stanza + full backup) -> rows before T -> rows after T ->
# WAL archived -> pitr restore --target T -> only the rows before T are there, the stack is
# healthy, and the repo has a new timeline. WHY: a recovery path that was never exercised
# is a guess, and PITR is the one we'd reach for after a bad migration on prd.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "pitr-it skipped (no docker)"; exit 0; }
M="$PWD/src/shell/db/docker-db-server-manager.sh"
W="$(mktemp -d /tmp/vsw-pitr.XXXX)"; D="$W/vswpitr"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { rm -rf /tmp/vsw-pitr-last; mkdir -p /tmp/vsw-pitr-last; cp "$W"/*.out "$DBM_LOG" /tmp/vsw-pitr-last/ 2>/dev/null || true
  [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
  docker ps -aq --filter name=vsw-rt- | xargs -r docker rm -f >/dev/null 2>&1 || true; it_purge vswpitr; rm -rf "$W"; }
trap cleanup EXIT
[ "${IT_KEEP:-0}" = 1 ] && trap 'echo "kept: $W (W=$W D=$D)"' EXIT
printf 'PG_BASE_IMAGE=postgres:18\nPG_IMAGE=vsw-test/postgres:18\n' > "$W/dbm.conf"; chmod 600 "$W/dbm.conf"
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$W/dbm.conf" \
  DBM_LOCK="$W/lock" DBM_LOG="$W/run.log" BACKUP_DIR="$W/backups" MIN_FREE_MB=10 \
  STATE_DIR="$W/state" ENV_SECRETS_DIR="$W/secrets" OFFSITE_CREDS_FILE="$W/offsite.env" \
  DOCKER_SUBNET=172.30.96.0/24 DOCKER_NETWORK=vsw_pitr \
  ENABLE_MYSQL=0 ENABLE_MARIADB=0 ENABLE_ADMINER=0 PG_PORT=25461 PGBOUNCER_PORT=26461 \
  PG_EXTENSIONS="pg_trgm" PG_USER=app PG_DB=app PITR=pgbackrest PITR_REPO_TYPE=posix
run()  { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }
dcx()  { (cd "$D" && docker compose --env-file .env --env-file stack.env "$@"); }
psq()  { dcx exec -T postgres psql -X -tA -U vsw_admin -d app -c "$1"; }
archived() { # wait until the current WAL segment is in the repo
  local w _; w="$(psq 'select pg_walfile_name(pg_switch_wal())')"
  for _ in $(seq 1 60); do [ "$(psq "select coalesce(last_archived_wal >= '$w', false) from pg_stat_archiver")" = t ] && return 0; sleep 1; done; return 1
}

run cmd_install > "$W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$W/install.out" && ok "install with PITR=pgbackrest (posix repo)" || { tail -40 "$W/install.out"; fail "install"; }
run cmd_pitr setup > "$W/setup.out" 2>&1 && grep -q 'PITR ready' "$W/setup.out" && ok "pitr setup: stanza + full backup" || { tail -40 "$W/setup.out"; fail "pitr setup"; }
# pgBackRest echoes its options but masks secrets as <redacted>; fail on the real value or any unmasked option
cp_val="$(sed -n 's/^PITR_CIPHER_PASS=//p' "$D/.env" 2>/dev/null || true)"
{ [ -n "$cp_val" ] && grep -qF "$cp_val" "$W/setup.out"; } || grep -qE 'cipher-pass=[^<]|CIPHER_PASS=' "$W/setup.out" \
  && fail "cipher pass printed" || ok "pitr setup: repo cipher pass not printed (pgBackRest masks it)"
psq 'create table t_pitr (id int primary key); insert into t_pitr select generate_series(1, 100)' >/dev/null
archived || fail "WAL before T not archived"
sleep 2; T="$(psq "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00'")"; sleep 2
psq 'insert into t_pitr select generate_series(101, 150); delete from t_pitr where id <= 10' >/dev/null
archived || fail "WAL after T not archived"
[ "$(psq 'select count(*) from t_pitr')" = 140 ] && ok "rows after T: 140 (50 added, 10 deleted)" || fail "setup rows"
run cmd_pitr status > "$W/status.out" 2>&1 && grep -q 'status: ok' "$W/status.out" && ok "pitr status: stanza ok" || { cat "$W/status.out"; fail "pitr status"; }
if run cmd_pitr restore > "$W/r0.out" 2>&1; then fail "restore without --target accepted"; fi
grep -q 'usage: pitr restore --target' "$W/r0.out" && ok "pitr restore needs --target" || fail "restore usage"
if FORCE=1 run cmd_pitr restore --target "$T" </dev/null > "$W/r1.out" 2>&1; then fail "prd restore without --force-prod accepted"; fi
grep -q 'force-prod' "$W/r1.out" && ok "pitr restore on a prd cluster refused without --force-prod" || { cat "$W/r1.out"; fail "restore guard"; }
WORKBENCH_CONFIRM=prd FORCE=1 run cmd_pitr restore --target "$T" --force-prod </dev/null > "$W/restore.out" 2>&1 && grep -q 'PITR restore done' "$W/restore.out" || { tail -40 "$W/restore.out"; fail "pitr restore"; }
n="$(psq 'select count(*) || '"' '"' || min(id) || '"' '"' || max(id) from t_pitr')"
[ "$n" = "100 1 100" ] && ok "pitr restore --target T: exactly the 100 rows from before T" || fail "after restore: $n (want 100 1 100)"
ls "$BACKUP_DIR"/*/manifest.txt >/dev/null 2>&1 && ok "restore took a dump backup first" || fail "no pre-restore backup"
run cmd_verify > "$W/verify.out" 2>&1 && ok "verify after restore (postgres + pgbouncer)" || { tail -20 "$W/verify.out"; fail "verify"; }
[ "$(psq 'select pg_is_in_recovery()')" = f ] && ok "promoted: writable after recovery" || fail "still in recovery"
run cmd_pitr backup full > "$W/full.out" 2>&1 && ok "pitr backup full on the new timeline" || { tail -20 "$W/full.out"; fail "full after restore"; }
echo "pitr-it: $pass checks passed"
