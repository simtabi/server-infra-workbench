#!/usr/bin/env bash
# Integration test of MySQL/MariaDB point-in-time restore (`make it`): binlog-replay in a throwaway
# stack, once per engine. backup (dump with binlog coordinates) -> rows, a new database and a new
# user before T -> rows deleted, the database dropped and the password rotated after T ->
# binlog-replay --target T -> exactly the data from T, the user keeps today's password (account
# statements are not replayed), a safety backup and a new backup exist, verify passes.
# WHY: the docs said "replay binlogs by hand with mysqlbinlog", and the mysql image has no
# mysqlbinlog at all. A recovery path that was never run is a guess.
# MYSQL_PITR_ENGINES="mysql" limits the engines (default: mysql mariadb).
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "mysql-pitr-it skipped (no docker)"; exit 0; }
M="$PWD/src/shell/db/docker-db-server-manager.sh"
W="$(mktemp -d /tmp/vsw-mypitr.XXXX)"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { rm -rf /tmp/vsw-mypitr-last; mkdir -p /tmp/vsw-mypitr-last; cp "$W"/*/*.out /tmp/vsw-mypitr-last/ 2>/dev/null || true
  local d; for d in "$W"/*/vswmypitr*; do [ -d "$d" ] && (cd "$d" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true; done
  docker ps -aq --filter name=vsw-mybl-build- | xargs -r docker rm -f >/dev/null 2>&1 || true
  it_purge vswmypitrmysql vswmypitrmariadb; rm -rf "$W"; }
trap cleanup EXIT
[ "${IT_KEEP:-0}" = 1 ] && trap 'echo "kept: $W"' EXIT
export DOCTOR_DISK_WARN_PCT=100 DOCTOR_DISK_BAD_PCT=100
run() { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }

scenario() { # engine subnet port
  local e="$1" E="$W/$1" D cli=mysql rv=MYSQL_ROOT_PASSWORD my=0 ma=0 b
  [ "$e" = mariadb ] && cli=mariadb rv=MARIADB_ROOT_PASSWORD ma=1 || my=1
  D="$E/vswmypitr$e"; mkdir -p "$E"
  printf 'PG_BASE_IMAGE=postgres:18\nPG_IMAGE=vsw-test/postgres:18\n' > "$E/dbm.conf"; chmod 600 "$E/dbm.conf"
  export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$E/dbm.conf" \
    DBM_LOCK="$E/lock" DBM_LOG="$E/run.log" BACKUP_DIR="$E/backups" MIN_FREE_MB=10 \
    STATE_DIR="$E/state" ENV_SECRETS_DIR="$E/secrets" DOCKER_SUBNET="$2" DOCKER_NETWORK="vsw_mypitr_$e" \
    ENABLE_POSTGRES=0 ENABLE_PGBOUNCER=0 ENABLE_MYSQL=$my ENABLE_MARIADB=$ma ENABLE_ADMINER=0 \
    MYSQL_PORT="$3" MARIADB_PORT="$3"
  dcx() { (cd "$D" && docker compose --env-file .env --env-file stack.env "$@"); }
  myq() { dcx exec -T "$e" sh -c "MYSQL_PWD=\"\$$rv\" exec $cli -uroot -NB" <<< "$1"; }
  # the app user logs in over TCP with a password made now (never printed)
  login() { dcx exec -T -e "MYSQL_PWD=$2" "$e" $cli -h127.0.0.1 -ulate -NBe 'select 1' 2>/dev/null; }
  run cmd_install > "$E/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$E/install.out" && ok "$e: install" || { it_why "$E/install.out" 40; fail "$e install"; }
  myq 'create database shop; create table shop.t (id int primary key); insert into shop.t with recursive s(n) as (select 1 union all select n + 1 from s where n < 100) select n from s;'
  run cmd_backup > "$E/backup.out" 2>&1 && ok "$e: backup" || { it_why "$E/backup.out" 30; fail "$e backup"; }
  b="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -name '20*' | sort | tail -1)"
  [ -n "$(run dump_coords "$b/$e.sql.gz")" ] && [ -s "$b/$e.completed-utc" ] && ok "$e: dump records its binlog coordinates + finish time (UTC)" || fail "$e: no coordinates in $b"
  sleep 1
  local p1 p2; p1="$(openssl rand -hex 16)"; p2="$(openssl rand -hex 16)"
  myq "insert into shop.t with recursive s(n) as (select 101 union all select n + 1 from s where n < 120) select n from s;
create database late_db; create table late_db.t2 (id int primary key); insert into late_db.t2 values (1),(2),(3),(4),(5);
create user 'late'@'%' identified by '$p1'; grant select on shop.* to 'late'@'%';"
  sleep 2; local T; T="$(myq "select date_format(utc_timestamp(), '%Y-%m-%d %H:%i:%s')")"; sleep 2
  myq "insert into shop.t values (500); delete from shop.t where id <= 10; drop database late_db; alter user 'late'@'%' identified by '$p2';"
  [ "$(myq 'select count(*) from shop.t')" = 111 ] && ok "$e: after T: 111 rows, late_db dropped, password rotated" || fail "$e setup rows"
  run cmd_binlog_ship > "$E/ship.out" 2>&1 && grep -q "shipped $e" "$E/ship.out" && ok "$e: binlog-ship" || { it_why "$E/ship.out" 20; fail "$e ship"; }
  if run cmd_binlog_replay --engine "$e" > "$E/r0.out" 2>&1; then fail "$e: replay without --target accepted"; fi
  grep -q "usage: binlog-replay --target" "$E/r0.out" && ok "$e: binlog-replay needs --target" || { cat "$E/r0.out"; fail "$e usage"; }
  if FORCE=1 run cmd_binlog_replay --target "$T" </dev/null > "$E/r1.out" 2>&1; then fail "$e: prd replay without --force-prod accepted"; fi
  grep -q 'force-prod' "$E/r1.out" && ok "$e: replay on a prd server refused without --force-prod" || { cat "$E/r1.out"; fail "$e guard"; }
  local nb; nb="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -name '20*' | wc -l | tr -d ' ')"
  WORKBENCH_CONFIRM=prd FORCE=1 run cmd_binlog_replay --target "$T" --force-prod </dev/null > "$E/replay.out" 2>&1 \
    && grep -q 'binlog replay done' "$E/replay.out" && ok "$e: binlog-replay --target T" || { it_why "$E/replay.out" 40; fail "$e replay"; }
  local n; n="$(myq "select concat(count(*), ' ', min(id), ' ', max(id)) from shop.t")"
  [ "$n" = "120 1 120" ] && ok "$e: exactly the 120 rows from T (the backup's 100 + 20 replayed)" || fail "$e after replay: $n (want 120 1 120)"
  [ "$(myq 'select count(*) from late_db.t2' 2>/dev/null)" = 5 ] && ok "$e: database created after the backup is back (5 rows)" || fail "$e: late_db missing"
  login "$e" "$p2" >/dev/null && ok "$e: user keeps today's password (account statements not replayed)" || fail "$e: rotated password lost"
  grep -q 'skipped [0-9]* account statement' "$E/replay.out" && ok "$e: skipped account statements reported" || fail "$e: no skipped count"
  [ "$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -name '20*' | wc -l | tr -d ' ')" -ge $((nb + 2)) ] && ok "$e: safety backup before + new backup after" || fail "$e: backups"
  ! ls -d "$BACKUP_DIR"/.replay-* >/dev/null 2>&1 && ok "$e: replay scratch removed" || fail "$e: scratch left"
  run cmd_verify > "$E/verify.out" 2>&1 && ok "$e: verify after the replay" || { it_why "$E/verify.out" 20; fail "$e verify"; }
  local rp; rp="$(sed -n "s/^$rv=//p" "$D/.env")"
  ! grep -qF -e "$rp" -e "$p1" -e "$p2" "$E"/*.out && ok "$e: no passwords in the output" || fail "$e: a password was printed"
  (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
}

for eng in ${MYSQL_PITR_ENGINES:-mysql mariadb}; do
  case "$eng" in
    mysql) scenario mysql 172.30.93.0/24 "$(it_port 23326)" ;;
    mariadb) scenario mariadb 172.30.92.0/24 "$(it_port 23327)" ;;
    *) fail "unknown engine $eng" ;;
  esac
done
echo "mysql-pitr-it: $pass checks passed"
