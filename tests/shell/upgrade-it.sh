#!/usr/bin/env bash
# Integration test of the manager against throwaway containers (Docker/OrbStack on a
# workstation). Not part of `make ci` (needs Docker, ~5 min): run `make it`.
# 1. install with the PREVIOUS manager (1.3: app login = superuser, root@'%')
# 2. upgrade to this one: dry run, fail-safes, forced failure -> rollback of the role split,
#    happy path (role split, citext, root@'%' gone, pgbouncer auth_query), idempotent re-run
# 3. privilege model per engine, environments + guard rails, backup + restore-test,
#    doctor flags a deviation, validation, lock, log redaction. Cleans up afterwards.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "upgrade-it skipped (no docker)"; exit 0; }
M="$PWD/src/shell/db/docker-db-server-manager.sh"
W="$(mktemp -d /tmp/vsw-up.XXXX)"; D="$W/vswitdb"
# the newest commit whose manager is 1.3.0 (override: OLD_REF=<commit>)
if [ -z "${OLD_REF:-}" ]; then
  for c in $(git log --format=%h -- src/shell/db/docker-db-server-manager.sh); do
    v="$(git show "$c:src/shell/db/docker-db-server-manager.sh" | sed -n 's/^VERSION="\(.*\)"$/\1/p')"
    [ "$v" = 1.3.0 ] && { OLD_REF="$c"; break; }
  done
fi
[ -n "$OLD_REF" ] || { echo "no 1.3.0 manager in history"; exit 1; }
git show "$OLD_REF:src/shell/db/docker-db-server-manager.sh" > "$W/old.sh"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
# outputs of a failed run are kept in /tmp/vsw-it-last (no secrets: passwords are never printed)
cleanup() { rm -rf /tmp/vsw-it-last; mkdir -p /tmp/vsw-it-last; cp "$W"/*.out "$DBM_LOG" /tmp/vsw-it-last/ 2>/dev/null || true
  [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
  docker ps -aq --filter name=vsw-rt- | xargs -r docker rm -f >/dev/null 2>&1 || true; it_purge vswitdb; rm -rf "$W"; }
trap cleanup EXIT
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$W/none.conf" \
  DBM_LOCK="$W/lock" DBM_LOG="$W/upgrade.log" BACKUP_DIR="$W/backups" MIN_FREE_MB=10 \
  STATE_DIR="$W/state" ENV_SECRETS_DIR="$W/secrets" DOCKER_SUBNET=172.30.99.0/24 \
  ENABLE_MYSQL=0 ENABLE_ADMINER=0 PG_PORT=25432 PGBOUNCER_PORT=26432 MARIADB_PORT=23307 \
  PG_BASE_IMAGE=postgres:18 PG_IMAGE=vsw-test/postgres:18 PGVECTOR_PKG=postgresql-18-pgvector \
  PG_EXTENSIONS="vector pg_trgm citext" MARIADB_IMAGE=mariadb:11 PG_USER=app PG_DB=app PGBOUNCER_POOL_SIZE=20
# run a manager command like main does, without the root check (workstation test)
run()  { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }
runo() { bash -c 'source <(sed "/^# ---- main/,\$d" "$1"); shift; need_root(){ :; }; check_engines; take_lock; "$@"' _ "$W/old.sh" "$@"; }
dcx()  { (cd "$D" && docker compose --env-file .env --env-file stack.env "$@"); }
psq()  { dcx exec -T postgres psql -X -tA -U "$1" -d "$2" -c "$3"; }
myq()  { dcx exec -T mariadb sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -N -B' <<<"$1"; }

# ---- 1. the 1.3 server --------------------------------------------------------------
runo cmd_install > "$W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$W/install.out" && ok "install with the previous manager ($OLD_REF)" || { tail -30 "$W/install.out"; fail "install"; }
[ "$(psq app postgres "select rolsuper from pg_roles where rolname='app'")" = t ] && [ -n "$(myq "select 1 from mysql.user where user='root' and host='%'")" ] \
  && ok "1.3 baseline: app is superuser, root@'%' exists" || fail "baseline"

[ -z "${IT_STOP_AFTER_INSTALL:-}" ] || { trap - EXIT; echo "left running in $W"; exit 0; }
# ---- 2. upgrade --------------------------------------------------------------------------
run cmd_upgrade --dry-run > "$W/dry.out" 2>&1 && grep -q 'dry run: nothing changed' "$W/dry.out" && grep -q '^+PG_ADMIN_USER=vsw_admin' "$W/dry.out" \
  && grep -q 'role split' "$W/dry.out" && ! grep -q '^PG_ADMIN_USER' "$D/stack.env" && ok "dry run shows the diff + role split, changes nothing" || { cat "$W/dry.out"; fail "dry run"; }
if run cmd_upgrade --non-interactive --yes </dev/null > "$W/ni.out" 2>&1; then fail "non-interactive without snapshot decision"; fi
grep -q 'no-snapshot' "$W/ni.out" && ok "non-interactive run fails safe without a snapshot decision" || { cat "$W/ni.out"; fail "ni"; }
if FORCE=0 run cmd_upgrade --no-snapshot </dev/null > "$W/noyes.out" 2>&1; then fail "apply without --yes"; fi
grep -q 'needs --yes' "$W/noyes.out" && ok "no tty + no --yes refuses to apply" || { cat "$W/noyes.out"; fail "noyes"; }

if DBM_TEST_FAIL_VERIFY=1 FORCE=1 run cmd_upgrade --no-snapshot </dev/null > "$W/rb.out" 2>&1; then fail "forced failure returned 0"; fi
grep -q 'ROLLBACK OK' "$W/rb.out" && [ "$(psq app postgres "select rolsuper from pg_roles where rolname='app'")" = t ] \
  && [ "$(psq app postgres "select count(*) from pg_roles where rolname='vsw_admin'")" = 0 ] && ! grep -q '^PG_ADMIN_USER' "$D/stack.env" \
  && dcx ps --format '{{.Health}}' | grep -vq unhealthy && ok "forced verify failure during the first 1.4 upgrade -> role split + files rolled back" || { tail -60 "$W/rb.out"; fail "rollback"; }

FORCE=1 DBM_TEST_NO_ROLLBACK="${IT_NO_ROLLBACK:-0}" run cmd_upgrade --no-snapshot </dev/null > "$W/up.out" 2>&1 && grep -q 'UPGRADE OK' "$W/up.out" && grep -q 'backup verified' "$W/up.out" \
  || { dcx logs --tail 60 pgbouncer postgres > "$W/svc-logs.out" 2>&1 || true; tail -60 "$W/up.out"; fail "upgrade"; }
ok "upgrade applied: backup verified, savepoint, converge, verify, doctor"
[ "$(psq vsw_admin postgres "select string_agg(rolname, ',' order by rolname) from pg_roles where rolsuper")" = vsw_admin ] \
  && [ "$(psq vsw_admin postgres "select rolcreatedb::text||rolcreaterole::text||rolbypassrls::text from pg_roles where rolname='app'")" = truefalsefalse ] \
  && ok "role split: vsw_admin is the only superuser; app keeps CREATEDB only (PG_APP_CREATEDB=1), no CREATEROLE/BYPASSRLS" || fail "role split"
[ "$(psq vsw_admin template1 "select count(*) from pg_extension where extname='citext'")" = 1 ] && [ "$(psq vsw_admin app "select count(*) from pg_extension where extname='citext'")" = 1 ] \
  && ok "citext in template1 and the main database" || fail "citext"
[ -z "$(myq "select 1 from mysql.user where user='root' and host='%'")" ] && [ "$(myq "select @@local_infile")" = 0 ] && [ -n "$(myq "select @@secure_file_priv")" ] \
  && ok "mariadb: root@'%' dropped, local_infile=0, secure_file_priv set" || fail "mariadb hardening"
pw="$(grep '^PG_PASSWORD=' "$D/.env" | cut -d= -f2-)"
docker run --rm --network host -e PGPASSWORD="$pw" postgres:18 psql -X -tA -h 127.0.0.1 -p 26432 -U app -d app -c 'create table t_it(id int); insert into t_it values (1); select count(*) from t_it' 2>&1 | grep -qx 1 \
  && ok "app logs in through PgBouncer (auth_query) and can migrate" || fail "pgbouncer login"
apw="$(grep '^PG_ADMIN_PASSWORD=' "$D/.env" | cut -d= -f2-)"
if docker run --rm --network host -e PGPASSWORD="$apw" postgres:18 psql -X -tA -h 127.0.0.1 -p 26432 -U vsw_admin -d app -c 'select 1' >/dev/null 2>&1; then fail "superuser via pgbouncer"; fi
ok "superuser cannot log in through PgBouncer"
FORCE=1 run cmd_upgrade --no-snapshot </dev/null > "$W/again.out" 2>&1 && grep -q 'already up to date' "$W/again.out" && ok "idempotent re-run: nothing to do" || { tail -20 "$W/again.out"; fail "idempotent"; }

# ---- 3. privilege model -------------------------------------------------------------------
run cmd_create_db shop --readonly-user --out "$W/shop.creds" > "$W/cdb.out" 2>&1 || { cat "$W/cdb.out"; fail "create-db"; }
ok_pw="$(grep '^DB_PASSWORD=' "$W/shop.creds" | head -1 | cut -d= -f2-)"
[ "$(stat -c %a "$W/shop.creds" 2>/dev/null || stat -f %Lp "$W/shop.creds")" = 600 ] && ! grep -qF "$ok_pw" "$W/cdb.out" && ok "create-db: credentials only in the 600 file" || fail "creds file"
psq shop shop 'create table a(id int); insert into a values (1)' >/dev/null && ! psq shop_ro shop 'insert into a values (2)' >/dev/null 2>&1 \
  && [ "$(psq shop_ro shop 'select count(*) from a')" = 1 ] && ! psq shop app 'select 1' >/dev/null 2>&1 && ! psq shop shop 'drop database shop' >/dev/null 2>&1 \
  && ok "postgres: owner migrates, read-only reads only, no other DBs, cannot drop its database" || fail "pg privileges"
run cmd_create_db shop2 mariadb --readonly-user --out "$W/shop2.creds" > "$W/cdb2.out" 2>&1 || { cat "$W/cdb2.out"; fail "create-db mariadb"; }
g="$(myq "show grants for 'shop2'@'$(bash -c 'm="$1"; set --; DBM_SOURCE_ONLY=1 source "$m"; my_host_of "$DOCKER_SUBNET"' _ "$M")'" 2>/dev/null || myq "select concat(user,'@',host) from mysql.user where user='shop2'")"
echo "$g" | grep -q 'shop2' && ! echo "$g" | grep -qiE 'ON \*\.\*.*(SELECT|INSERT|FILE|SUPER|PROCESS)|GRANT OPTION' && ok "mariadb: grants on shop2.* only, no global privileges" || { echo "$g"; fail "my grants"; }

# ---- environments + guard rails ------------------------------------------------------------
export APP=itapp ENVS="dev prd" TENANT_ENVS=dev PROTECTED_ENVS=prd
run cmd_env_apply > "$W/envs.out" 2>&1 || { tail -30 "$W/envs.out"; fail "env-apply"; }
[ "$(psq vsw_admin postgres "select count(*) from pg_database where datname in ('itapp_dev','itapp_prd')")" = 2 ] \
  && [ "$(psq vsw_admin postgres "select rolcreatedb from pg_roles where rolname='itapp_dev_app'")" = t ] && [ "$(psq vsw_admin postgres "select rolcreatedb from pg_roles where rolname='itapp_prd_app'")" = f ] \
  && [ "$(stat -c %a "$ENV_SECRETS_DIR/prd.env" 2>/dev/null || stat -f %Lp "$ENV_SECRETS_DIR/prd.env")" = 600 ] && ok "env-apply: per-env DBs + roles, CREATEDB only where tenants are on, secrets 600" || { cat "$W/envs.out"; fail "envs"; }
run cmd_env_apply > "$W/envs2.out" 2>&1 && ok "env-apply is idempotent" || fail "env-apply rerun"
if run cmd_drop_db itapp_prd </dev/null > "$W/d1.out" 2>&1; then fail "prd drop without --force-prod"; fi
grep -q 'force-prod' "$W/d1.out" && ok "drop-db on prd refused without --force-prod" || { cat "$W/d1.out"; fail "guard 1"; }
WORKBENCH_CONFIRM=prd FORCE=1 run cmd_drop_db itapp_prd --force-prod </dev/null > "$W/d2.out" 2>&1 || { cat "$W/d2.out"; fail "guarded drop"; }
grep -q 'backup' "$W/d2.out" && [ -n "$(psq vsw_admin postgres "select 1 from pg_database where datname like 'itapp_prd__trash_%'")" ] \
  && ok "prd drop with --force-prod + typed name: fresh backup, soft-deleted to trash" || { cat "$W/d2.out"; fail "soft drop"; }
run cmd_env_apply >/dev/null 2>&1
unset APP ENVS TENANT_ENVS PROTECTED_ENVS

# ---- backup + restore test ---------------------------------------------------------------------
run cmd_backup > "$W/bk.out" 2>&1 && b="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '2*' | sort | tail -1)" && [ -f "$b/manifest.txt" ] && [ -f "$b/SHA256SUMS" ] \
  && ok "backup: dumps + manifest + checksums" || { cat "$W/bk.out"; fail "backup"; }
run cmd_restore_test > "$W/rt.out" 2>&1 && grep -q 'restore test OK' "$W/rt.out" && ok "restore-test: loads into throwaway containers, manifest matches" || { tail -30 "$W/rt.out"; fail "restore-test"; }
[ -z "$(docker ps -aq --filter name=vsw-rt-)" ] && ok "restore-test: throwaway containers removed" || fail "restore-test left vsw-rt-* containers behind"

# ---- doctor flags a deviation ---------------------------------------------------------------------
run cmd_doctor > "$W/doc.out" 2>&1 && ! grep -q PROBLEM "$W/doc.out" && ok "doctor clean after upgrade" || { cat "$W/doc.out"; fail "doctor clean"; }
psq vsw_admin postgres 'alter role app superuser' >/dev/null
if run cmd_doctor > "$W/doc2.out" 2>&1; then fail "doctor missed a superuser app"; fi
grep -q 'PROBLEM.*superuser' "$W/doc2.out" && ok "doctor flags an app login that became superuser" || { cat "$W/doc2.out"; fail "doctor deviation"; }
psq vsw_admin postgres 'alter role app nosuperuser' >/dev/null

# ---- validation, lock, log -----------------------------------------------------------------
if PRIVATE_IP=999.1.1.1 FORCE=1 run cmd_upgrade --no-snapshot > "$W/bad.out" 2>&1; then fail "bad ip accepted"; fi
grep -q 'not an IPv4' "$W/bad.out" && ok "invalid PRIVATE_IP rejected before any change" || { cat "$W/bad.out"; fail "bad ip"; }
if PGBOUNCER_IMAGE=edoburu/pgbouncer:latest FORCE=1 run cmd_upgrade --no-snapshot > "$W/lat.out" 2>&1; then fail ":latest accepted"; fi
grep -q 'pin a version' "$W/lat.out" && ok ":latest image rejected" || { cat "$W/lat.out"; fail "latest"; }
sleep 60 & holder=$!; mkdir "$DBM_LOCK"; echo "$holder" > "$DBM_LOCK/pid"
if FORCE=1 run cmd_upgrade --no-snapshot > "$W/lock.out" 2>&1; then fail "lock ignored"; fi
grep -q 'another run is in progress' "$W/lock.out" && ok "lock conflict refused" || { cat "$W/lock.out"; fail "lock"; }
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true; rm -rf "$DBM_LOCK"
[ -s "$DBM_LOG" ] && ! grep -qF "$pw" "$DBM_LOG" && ! grep -qF "$apw" "$DBM_LOG" && [ "$(stat -c %a "$DBM_LOG" 2>/dev/null || stat -f %Lp "$DBM_LOG")" = 600 ] \
  && ok "log written, chmod 600, no secrets" || fail "log redaction"
echo "upgrade-it: all $pass checks passed"
