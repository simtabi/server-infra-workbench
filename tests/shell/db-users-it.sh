#!/usr/bin/env bash
# Integration test of the 1.6.0 database user flow and engine toggles against throwaway containers
# (`make it`, ONLY=db-users-it): master users per engine (MySQL/MariaDB named admin, Postgres bootstrap
# admin), admin-creds (600 file, never printed), create-db / create-user idempotency and least-privilege
# grants, superuser owners refused, and `engines apply`: MySQL + MariaDB off with Postgres serving queries
# the whole time (same container), volumes kept, re-enable brings the data back, --purge deletes it.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "db-users-it skipped (no docker)"; exit 0; }
M="$PWD/src/shell/db/docker-db-server-manager.sh"
W="$(mktemp -d /tmp/siw-dbu.XXXX)"; D="$W/vswdbu"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { [ -n "${PROBE:-}" ] && kill "$PROBE" 2>/dev/null || true
  rm -rf /tmp/siw-dbu-last; mkdir -p /tmp/siw-dbu-last; cp "$W"/*.out "$DBM_LOG" /tmp/siw-dbu-last/ 2>/dev/null || true
  [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
  docker volume rm vswdbu_mysql_data vswdbu_mariadb_data vswdbu_pg_data >/dev/null 2>&1 || true
  it_purge vswdbu; rm -rf "$W"; }
trap cleanup EXIT
[ "${IT_KEEP:-0}" = 1 ] && trap 'echo "kept: $W (W=$W D=$D)"' EXIT
# ENABLE_* live in the config file: engines apply rewrites them there (the environment would win)
cat > "$W/dbm.conf" <<CONF
PG_BASE_IMAGE=postgres:18
PG_IMAGE=vsw-test/postgres:18
PGVECTOR_PKG=postgresql-18-pgvector
ENABLE_POSTGRES=1
ENABLE_PGBOUNCER=1
ENABLE_MYSQL=1
SIWO_DB_ENABLE_MARIADB=1
ENABLE_ADMINER=0
CONF
chmod 600 "$W/dbm.conf"
export DOCTOR_DISK_WARN_PCT=100 DOCTOR_DISK_BAD_PCT=100
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$W/dbm.conf" \
  DBM_LOCK="$W/lock" DBM_LOG="$W/run.log" BACKUP_DIR="$W/backups" MIN_FREE_MB=10 \
  STATE_DIR="$W/state" ENV_SECRETS_DIR="$W/secrets" DOCKER_SUBNET=172.30.97.0/24 DOCKER_NETWORK=vsw_dbu \
  PG_PORT=25452 PGBOUNCER_PORT=26452 MYSQL_PORT=23326 MARIADB_PORT=23327 \
  PG_EXTENSIONS="pg_trgm citext" PG_USER=app PG_DB=app TLS_MODE=off FORCE=1
run()  { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }
dcx()  { (cd "$D" && docker compose --env-file .env --env-file stack.env "$@"); }
psq()  { dcx exec -T postgres psql -X -tA -U "$1" -d "$2" -c "$3"; }
cid()  { docker ps -q --no-trunc --filter label=com.docker.compose.project=vswdbu --filter "label=com.docker.compose.service=$1"; }
envv() { grep "^$1=" "$D/.env" | cut -d= -f2-; }   # a generated secret, used in a variable only (never printed)
f600() { [ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" = 600 ]; }
# my <engine> <user> <password> <sql>: a client over the published port, like a DB client through a tunnel
my() { local img=mysql:9.7 cli=mysql port=23326; [ "$1" = mariadb ] && img=mariadb:13 cli=mariadb port=23327
  docker run --rm --network host -e MYSQL_PWD="$3" "$img" "$cli" -h127.0.0.1 -P"$port" --protocol=TCP -u"$2" -N -B -e "$4"; }
pgc() { docker run --rm --network host -e PGPASSWORD="$3" postgres:18 psql -X -tA -h 127.0.0.1 -p "$1" -U "$2" -d "$4" -c "$5"; }

# ---- install: all four engines, master users ------------------------------------------
run cmd_install > "$W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$W/install.out" && ok "install: postgres + pgbouncer + mysql + mariadb" || { it_why "$W/install.out" 40; fail "install"; }
f600 "$D/.env" && [ -n "$(envv MYSQL_ADMIN_PASSWORD)" ] && [ -n "$(envv MARIADB_ADMIN_PASSWORD)" ] && [ -n "$(envv PG_ADMIN_PASSWORD)" ] \
  && ! cat "$W/install.out" "$DBM_LOG" 2>/dev/null | grep -qF "$(envv MYSQL_ADMIN_PASSWORD)" && ok "master passwords generated into .env (600), never in output or log" || fail "master passwords"
for e in mysql mariadb; do pw="$(envv "$( [ $e = mysql ] && echo MYSQL || echo MARIADB)_ADMIN_PASSWORD")"
  hosts="$(printf "select host from mysql.user where user='siwo_admin' order by 1;\n" | run my_q "$e" | tr '\n' ' ')"
  [ "$hosts" = "127.0.0.0/255.0.0.0 172.30.97.0/255.255.255.0 " ] || fail "$e master hosts: $hosts"
  my "$e" siwo_admin "$pw" 'show grants' 2>/dev/null | grep -q 'ON \*\.\* TO .*WITH GRANT OPTION' \
    && ok "$e master siwo_admin: docker net + VPC only, ALL on *.* with grant option, logs in over the port" || fail "$e master login"
  printf "select count(*) from mysql.user where user='root' and host='%%';\n" | run my_q "$e" | grep -qx 0 || fail "$e root@%"
done
run converge > "$W/converge.out" 2>&1 && [ "$(printf "select count(*) from mysql.user where user='siwo_admin';\n" | run my_q mysql)" = 2 ] \
  && ok "converge is idempotent for the master users" || { it_why "$W/converge.out" 20; fail "converge rerun"; }

run cmd_doctor > "$W/doctor.out" 2>&1 || true
grep -q 'ok    master siwo_admin from:' "$W/doctor.out" && ! grep -q 'users with global privileges' "$W/doctor.out" \
  && ok "doctor: the master is the expected global login, no app user has global privileges" || { grep -E 'PROBLEM|master' "$W/doctor.out"; fail "doctor master"; }

# ---- admin-creds ---------------------------------------------------------------------------
if run cmd_admin_creds mysql > "$W/ac0.out" 2>&1; then fail "admin-creds without --out"; fi
run cmd_admin_creds mysql --out "$W/mysql-admin.creds" > "$W/ac.out" 2>&1 && f600 "$W/mysql-admin.creds" \
  && grep -q '^DB_USERNAME=siwo_admin$' "$W/mysql-admin.creds" && ! grep -q "$(envv MYSQL_ADMIN_PASSWORD)" "$W/ac.out" \
  && grep -q "^DB_PASSWORD=$(envv MYSQL_ADMIN_PASSWORD)$" "$W/mysql-admin.creds" && ok "admin-creds: 600 file only, never printed, --out required" || { cat "$W/ac.out"; fail "admin-creds"; }
run cmd_admin_creds postgres --out "$W/pg-admin.creds" > "$W/acp.out" 2>&1 && grep -q '^DB_USERNAME=vsw_admin$' "$W/pg-admin.creds" && grep -q '^DB_PORT=25452$' "$W/pg-admin.creds" \
  && grep -q 'PgBouncer' "$W/acp.out" && ok "admin-creds postgres: the bootstrap admin, direct port (not PgBouncer)" || fail "admin-creds pg"

# ---- create-db / create-user: least privilege + idempotent ----------------------------------
run cmd_create_db shop postgres --readonly-user --out "$W/shop.creds" > "$W/cdb1.out" 2>&1 && f600 "$W/shop.creds" && f600 "$W/shop.creds.readonly" \
  || { cat "$W/cdb1.out"; fail "create-db shop"; }
spw="$(grep '^DB_PASSWORD=' "$W/shop.creds" | cut -d= -f2-)"
[ "$(psq vsw_admin postgres "select rolsuper::int::text||rolcreaterole::int::text||rolcreatedb::int::text from pg_roles where rolname='shop'")" = 000 ] \
  && [ "$(psq vsw_admin shop "select pg_get_userbyid(nspowner) from pg_namespace where nspname='public'")" = shop ] \
  && ok "create-db: owner shop (no superuser/createrole/createdb) owns schema public" || fail "pg owner attrs"
pgc 26452 shop "$spw" shop "create table t(i int); insert into t values (1)" >/dev/null && pgc 26452 shop_ro "$(grep '^DB_PASSWORD=' "$W/shop.creds.readonly" | cut -d= -f2-)" shop "select count(*) from t" | grep -qx 1 \
  && ! pgc 26452 shop_ro "$(grep '^DB_PASSWORD=' "$W/shop.creds.readonly" | cut -d= -f2-)" shop "insert into t values (2)" >/dev/null 2>&1 \
  && ok "owner can DDL/DML through PgBouncer; <db>_ro reads, cannot write" || fail "pg grants"
run cmd_create_db shop postgres --readonly-user --out "$W/shop2.creds" > "$W/cdb2.out" 2>&1 && grep -q 'already existed' "$W/cdb2.out" && [ ! -e "$W/shop2.creds" ] \
  && pgc 26452 shop "$spw" shop "select count(*) from t" | grep -qx 1 && ok "create-db re-run: exit 0, grants re-applied, password and data unchanged, no new creds" || { cat "$W/cdb2.out"; fail "create-db rerun"; }
psq vsw_admin postgres "create role su_test superuser login" >/dev/null
if run cmd_create_db sudb postgres --owner su_test > "$W/su.out" 2>&1; then fail "superuser owner accepted"; fi
grep -q 'is a superuser' "$W/su.out" && ok "an existing superuser is refused as an app owner" || fail "superuser refusal msg"
if run cmd_create_db other postgres --owner siwo_admin > /dev/null 2>&1 || run cmd_create_db x postgres --owner vsw_admin >/dev/null 2>&1; then fail "master as owner"; fi
ok "master users cannot be used as app owners"
for e in mysql mariadb; do
  run cmd_create_db shop "$e" --out "$W/shop-$e.creds" > "$W/cdbm-$e.out" 2>&1 || { cat "$W/cdbm-$e.out"; fail "create-db $e"; }
  mpw="$(grep '^DB_PASSWORD=' "$W/shop-$e.creds" | cut -d= -f2-)"
  my "$e" shop "$mpw" 'create table shop.t (i int); insert into shop.t values (1)' >/dev/null
  g="$(my "$e" shop "$mpw" 'show grants')"
  printf '%s' "$g" | grep -q 'GRANT USAGE ON \*\.\*' && ! printf '%s' "$g" | grep -Eq 'ON \*\.\* .*(ALL|FILE|SUPER|PROCESS)|GRANT OPTION' \
    && printf '%s' "$g" | grep -q 'ON `shop`\.\*' || fail "$e grants: $g"
  run cmd_create_db shop "$e" > "$W/cdbm2-$e.out" 2>&1 && grep -q 'already existed' "$W/cdbm2-$e.out" && my "$e" shop "$mpw" 'select count(*) from shop.t' | grep -qx 1 \
    || { cat "$W/cdbm2-$e.out"; fail "$e create-db rerun"; }
  run cmd_create_user rep shop "$e" --readonly --out "$W/rep-$e.creds" >/dev/null 2>&1 && run cmd_create_user rep shop "$e" --readonly > "$W/cu2-$e.out" 2>&1 \
    && grep -q 'already existed' "$W/cu2-$e.out" || fail "$e create-user rerun"
  ok "$e: owner on shop.* only (no global privileges); create-db and create-user re-runs are idempotent"
done

# ---- engines: MySQL + MariaDB off, Postgres keeps serving -----------------------------------
run cmd_engines status > "$W/st0.out" 2>&1 && grep -Eq '^mysql +on +running' "$W/st0.out" || { cat "$W/st0.out"; fail "engines status"; }
pg_id="$(cid postgres)"; pgb_id="$(cid pgbouncer)"; pg_started="$(docker inspect -f '{{.State.StartedAt}}' "$pg_id")"
run cmd_engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0 --dry-run > "$W/dry.out" 2>&1 && grep -q 'dry run: nothing changed' "$W/dry.out" \
  && [ -n "$(cid mysql)" ] && grep -q '^ENABLE_MYSQL=1$' "$W/dbm.conf" && ok "engines apply --dry-run: plan only, nothing changed" || { cat "$W/dry.out"; fail "dry run"; }
# probe: a query through PgBouncer every 0.2 s while the other engines go away
( fails=0; while :; do pgc 26452 shop "$spw" shop "select 1" >/dev/null 2>&1 || fails=$((fails + 1)); echo "$fails" > "$W/probe.fails"; sleep 0.2; done ) & PROBE=$!
sleep 2
run cmd_engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0 > "$W/off.out" 2>&1 || { it_why "$W/off.out" 40; fail "engines apply off"; }
sleep 1; kill "$PROBE" 2>/dev/null || true; wait "$PROBE" 2>/dev/null || true; PROBE=""
[ -z "$(cid mysql)" ] && [ -z "$(cid mariadb)" ] && docker volume inspect vswdbu_mysql_data >/dev/null 2>&1 && docker volume inspect vswdbu_mariadb_data >/dev/null 2>&1 \
  && ok "mysql + mariadb containers removed, their volumes kept" || { cat "$W/off.out"; fail "engines off"; }
[ "$(cid postgres)" = "$pg_id" ] && [ "$(cid pgbouncer)" = "$pgb_id" ] && [ "$(docker inspect -f '{{.State.StartedAt}}' "$pg_id")" = "$pg_started" ] \
  && [ "$(cat "$W/probe.fails")" = 0 ] && grep -q 'untouched: postgres' "$W/off.out" \
  && ok "zero downtime: postgres + pgbouncer same containers, not restarted, 0 failed queries during apply" || { cat "$W/off.out"; echo "probe fails: $(cat "$W/probe.fails")"; fail "downtime"; }
grep -q '^ENABLE_MYSQL=0$' "$W/dbm.conf" && grep -q '^ENABLE_MARIADB=0$' "$W/dbm.conf" && ! grep -q '^SIWO_DB_ENABLE_MARIADB=' "$W/dbm.conf" && ! grep -q 'mysql:' "$D/docker-compose.yml" && ls -d "$BACKUP_DIR"/20* >/dev/null 2>&1 \
  && ok "config + compose updated, backup taken before the removal" || fail "config/compose/backup"
run cmd_engines status > "$W/st1.out" 2>&1 && grep -Eq '^mysql +off +absent .*vswdbu_mysql_data \(kept\)' "$W/st1.out" || { cat "$W/st1.out"; fail "status after off"; }
run cmd_engines apply > "$W/noop.out" 2>&1 && grep -q 'nothing to change' "$W/noop.out" && ok "engines apply is idempotent (nothing to change)" || fail "noop"

# ---- re-enable MySQL: data back; purge MariaDB ---------------------------------------------
run cmd_engines apply --set ENABLE_MYSQL=1 > "$W/on.out" 2>&1 || { it_why "$W/on.out" 40; fail "engines apply on"; }
my mysql shop "$(grep '^DB_PASSWORD=' "$W/shop-mysql.creds" | cut -d= -f2-)" 'select count(*) from shop.t' | grep -qx 1 && [ "$(cid postgres)" = "$pg_id" ] \
  && ok "mysql back on: same data and users, postgres untouched" || { cat "$W/on.out"; fail "re-enable"; }
if run cmd_engines apply --purge > "$W/purge0.out" 2>&1; then fail "purge without typed confirmation"; fi
docker volume inspect vswdbu_mariadb_data >/dev/null 2>&1 || fail "volume deleted without confirmation"
WORKBENCH_CONFIRM="DELETE vswdbu_mariadb_data" run cmd_engines apply --purge > "$W/purge.out" 2>&1 && ! docker volume inspect vswdbu_mariadb_data >/dev/null 2>&1 \
  && docker volume inspect vswdbu_mysql_data >/dev/null 2>&1 && ok "--purge deletes only the off engine's volume, after the typed confirmation" || { cat "$W/purge.out"; fail "purge"; }
run cmd_engine disable pgbouncer --dry-run > "$W/e1.out" 2>&1 && grep -q 'stop    pgbouncer' "$W/e1.out" && ok "engine disable <e> is engines apply --set (plan shown)" || { cat "$W/e1.out"; fail "engine alias"; }
if run cmd_engines apply --set ENABLE_POSTGRES=0 > /dev/null 2>&1; then fail "postgres off with pgbouncer on"; fi
ok "postgres cannot go off while pgbouncer needs it"
echo "db-users-it: all $pass checks passed"
