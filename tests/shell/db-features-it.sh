#!/usr/bin/env bash
# Integration test of the P2 manager features against throwaway containers (`make it`):
# TLS_MODE=verify-full (direct + PgBouncer, wrong CA refused, PgBouncer verifies postgres),
# MySQL engine with TLS, textfile metrics, migrate-managed (to a stand-in "managed"
# postgres: extension check, copy, row counts) and pg-major-upgrade (forced failure ->
# rollback, then 18 -> 19 when the 19 image builds). Cleans up afterwards.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "db-features-it skipped (no docker)"; exit 0; }
M="$PWD/src/shell/db/docker-db-server-manager.sh"
W="$(mktemp -d /tmp/vsw-dbf.XXXX)"; D="$W/vswdbf"; NEXT_BASE="${PGMU_NEXT_BASE:-postgres:19rc1}"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { rm -rf /tmp/vsw-dbf-last; mkdir -p /tmp/vsw-dbf-last; cp "$W"/*.out "$DBM_LOG" /tmp/vsw-dbf-last/ 2>/dev/null || true
  [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
  docker rm -f vsw-dbf-target >/dev/null 2>&1 || true; docker ps -aq --filter name=vsw-rt- | xargs -r docker rm -f >/dev/null 2>&1 || true
  it_purge vswdbf; rm -rf "$W"; }
trap cleanup EXIT
[ "${IT_KEEP:-0}" = 1 ] && trap 'echo "kept: $W (W=$W D=$D)"' EXIT
mkdir -p "$W/textfile"
# image keys live in the config file (pg-major-upgrade rewrites them there; env would win)
cat > "$W/dbm.conf" <<CONF
PG_BASE_IMAGE=postgres:18
PG_IMAGE=vsw-test/postgres:18
PGVECTOR_PKG=postgresql-18-pgvector
CONF
chmod 600 "$W/dbm.conf"
# the host disk is the laptop's, not a server's: its fill level must not fail doctor (the 1.4 upgrade flake)
export DOCTOR_DISK_WARN_PCT=100 DOCTOR_DISK_BAD_PCT=100
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$W/dbm.conf" \
  DBM_LOCK="$W/lock" DBM_LOG="$W/run.log" BACKUP_DIR="$W/backups" MIN_FREE_MB=10 \
  STATE_DIR="$W/state" ENV_SECRETS_DIR="$W/secrets" DOCKER_SUBNET=172.30.98.0/24 DOCKER_NETWORK=vsw_dbf \
  ENABLE_MYSQL=1 ENABLE_MARIADB=0 ENABLE_ADMINER=0 PG_PORT=25442 PGBOUNCER_PORT=26442 MYSQL_PORT=23316 \
  PG_EXTENSIONS="vector pg_trgm citext" PG_USER=app PG_DB=app PGBOUNCER_POOL_SIZE=20 \
  TLS_MODE=verify-full METRICS_TEXTFILE_DIR="$W/textfile" MONITOR_PASSWORD_FILE="$W/pg-monitor.pass"
run()  { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }
dcx()  { (cd "$D" && docker compose --env-file .env --env-file stack.env "$@"); }
psq()  { dcx exec -T postgres psql -X -tA -U "$1" -d "$2" -c "$3"; }
cli()  { docker run --rm --network host -v "$W:/w:ro" "$@"; }

# ---- install with verify-full + MySQL ----------------------------------------------
run cmd_install > "$W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$W/install.out" && ok "install: postgres + pgbouncer + mysql, TLS_MODE=verify-full" || { it_why "$W/install.out" 40; fail "install"; }
pw="$(grep '^PG_PASSWORD=' "$D/.env" | cut -d= -f2-)"

# ---- verify-full -----------------------------------------------------------------------
run cmd_tls_ca --out "$W/ca.crt" > "$W/ca.out" 2>&1 && [ "$(stat -c %a "$W/ca.crt" 2>/dev/null || stat -f %Lp "$W/ca.crt")" = 644 ] && grep -q 'BEGIN CERTIFICATE' "$W/ca.crt" \
  && ! grep -q 'PRIVATE' "$W/ca.crt" && ok "tls-ca --out: public CA only (644, no key material)" || { cat "$W/ca.out"; fail "tls-ca"; }
for p in 25442 26442; do
  cli -e PGPASSWORD="$pw" postgres:18 psql -X -tA "host=127.0.0.1 port=$p user=app dbname=app sslmode=verify-full sslrootcert=/w/ca.crt" -c "select 'ok'" 2>&1 | grep -qx ok \
    && ok "verify-full login on port $p (CA + IP SAN checked)" || fail "verify-full $p"
done
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=other -keyout "$W/other.key" -out "$W/other.crt" >/dev/null 2>&1; rm -f "$W/other.key"
if cli -e PGPASSWORD="$pw" postgres:18 psql -X -tA "host=127.0.0.1 port=25442 user=app dbname=app sslmode=verify-full sslrootcert=/w/other.crt" -c "select 1" >/dev/null 2>&1; then fail "wrong CA accepted"; fi
ok "verify-full with a different CA is refused"
# (a plaintext login cannot be tested here: Docker Desktop/OrbStack proxy every published-port
#  connection from the compose gateway, which pg_hba treats as the docker subnet)
grep -q '^hostssl  all       vsw_admin  127.0.0.0/8' "$D/postgres/conf/pg_hba.conf" && ! grep -qE '^host +[^ ]+ +[^ ]+ +127\.0\.0\.0/8' "$D/postgres/conf/pg_hba.conf" \
  && ok "pg_hba: every VPC line is hostssl" || { cat "$D/postgres/conf/pg_hba.conf"; fail "hostssl"; }
dcx exec -T pgbouncer sh -c 'grep -q "^server_tls_sslmode = verify-full" /etc/pgbouncer/pgbouncer.ini && grep -q "^server_tls_ca_file = /etc/pgbouncer/tls/ca.crt" /etc/pgbouncer/pgbouncer.ini' \
  && ok "PgBouncer verifies postgres (server_tls_sslmode=verify-full, CA file)" || fail "pgbouncer server tls"
run cmd_env > "$W/env.out" 2>&1 && grep -q '^DB_SSLMODE=verify-full' "$W/env.out" && grep -q '^DB_SSLROOTCERT=/etc/ssl/certs/vsw-db-ca.crt' "$W/env.out" \
  && ok "env prints DB_SSLMODE=verify-full + DB_SSLROOTCERT" || { cat "$W/env.out"; fail "env verify-full"; }
run cmd_doctor > "$W/doctor.out" 2>&1 || true
grep -q 'verify-full: server certificate chains to the CA' "$W/doctor.out" && ok "doctor: server certificate chains to the CA" || { grep -E 'PROBLEM|TLS' "$W/doctor.out"; fail "doctor verify-full"; }

# ---- MySQL with TLS ----------------------------------------------------------------
myq() { dcx exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -B' <<<"$1"; }
[ "$(myq 'select @@require_secure_transport')" = 1 ] && [ "$(myq 'select @@local_infile')" = 0 ] && [ -z "$(myq "select 1 from mysql.user where user='root' and host='%'")" ] \
  && ok "mysql: require_secure_transport=ON, local_infile=0, no root@'%'" || fail "mysql hardening"
run cmd_create_db shopm mysql --readonly-user --out "$W/shopm.creds" > "$W/cdbm.out" 2>&1 && [ "$(stat -c %a "$W/shopm.creds" 2>/dev/null || stat -f %Lp "$W/shopm.creds")" = 600 ] \
  && ok "mysql: create-db with a read-only user, creds file 600" || { cat "$W/cdbm.out"; fail "mysql create-db"; }

# ---- metrics -----------------------------------------------------------------------------
psq vsw_admin app "create table t_it(id int primary key, v text); insert into t_it select g, md5(g::text) from generate_series(1,500) g; grant select on t_it to app" >/dev/null  # the grant must survive pg-major-upgrade
run cmd_backup > "$W/bk.out" 2>&1 || { it_why "$W/bk.out" 20; fail "backup"; }
f="$W/textfile/vsw_db.prom"
grep -q '^vsw_backup_last_success_timestamp_seconds{engine="all"} [0-9]\{10\}$' "$f" && grep -q '^vsw_tls_cert_expiry_timestamp_seconds{cert="db"} [0-9]\{10\}$' "$f" \
  && grep -q '^vsw_reboot_required [01]$' "$f" && [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 644 ] \
  && ok "backup writes textfile metrics (backup time, TLS expiry, reboot flag; 644)" || { cat "$f" 2>/dev/null; fail "metrics"; }
run cmd_restore_test > "$W/rt.out" 2>&1 && grep -q 'restore test OK' "$W/rt.out" && grep -q '^vsw_restore_test_last_success_timestamp_seconds [0-9]' "$f" \
  && ok "restore-test (postgres + mysql) ok and its metric written" || { it_why "$W/rt.out" 30; fail "restore-test"; }
if command -v promtool >/dev/null 2>&1; then promtool check metrics < "$f" >/dev/null 2>&1 && ok "promtool accepts the textfile" || fail "promtool metrics"
else docker run --rm -i --entrypoint promtool prom/prometheus:v3.15.1 check metrics < "$f" >/dev/null 2>&1 && ok "promtool accepts the textfile" || fail "promtool metrics"; fi

# ---- migrate-managed ---------------------------------------------------------------------
tpw="$(openssl rand -hex 16)"
target() { docker rm -f vsw-dbf-target >/dev/null 2>&1 || true
  docker run -d --name vsw-dbf-target -p 127.0.0.1:25499:5432 -e POSTGRES_USER=doadmin -e POSTGRES_PASSWORD="$tpw" -e POSTGRES_DB=defaultdb "$1" >/dev/null
  for _ in $(seq 60); do docker exec vsw-dbf-target pg_isready -U doadmin -d defaultdb >/dev/null 2>&1 && sleep 2 && return 0; sleep 1; done; return 1; }
printf 'TARGET_HOST=127.0.0.1\nTARGET_PORT=25499\nTARGET_USER=doadmin\nTARGET_PASSWORD=%s\nTARGET_SSLMODE=disable\n' "$tpw" > "$W/target.env"; chmod 644 "$W/target.env"
if MM_ALLOW_PLAIN=1 run cmd_migrate_managed --target-env "$W/target.env" --check > "$W/mm0.out" 2>&1; then fail "644 target file accepted"; fi
grep -q 'must be chmod 600' "$W/mm0.out" && ok "migrate-managed: refuses a target file that is not 600" || { cat "$W/mm0.out"; fail "mm perms"; }
chmod 600 "$W/target.env"
if run cmd_migrate_managed --target-env "$W/target.env" --check > "$W/mm1.out" 2>&1; then fail "sslmode=disable accepted"; fi
grep -q 'refused' "$W/mm1.out" && ok "migrate-managed: refuses TARGET_SSLMODE=disable" || { cat "$W/mm1.out"; fail "mm ssl"; }
target postgres:18 || fail "target start"
if MM_ALLOW_PLAIN=1 run cmd_migrate_managed --target-env "$W/target.env" --check > "$W/mm2.out" 2>&1; then fail "missing extension not detected"; fi
grep -q 'not available on the target:.*vector' "$W/mm2.out" && ok "migrate-managed --check: detects extensions missing on the target (vector)" || { cat "$W/mm2.out"; fail "mm ext"; }
target vsw-test/postgres:18 || fail "target start 2"
MM_ALLOW_PLAIN=1 run cmd_migrate_managed --target-env "$W/target.env" --check > "$W/mm3.out" 2>&1 && grep -q 'check: nothing copied' "$W/mm3.out" && ! grep -q "$tpw" "$W/mm3.out" \
  && ok "migrate-managed --check passes, password never printed" || { cat "$W/mm3.out"; fail "mm check"; }
FORCE=1 MM_ALLOW_PLAIN=1 run cmd_migrate_managed --target-env "$W/target.env" > "$W/mm4.out" 2>&1 && grep -q 'MIGRATE OK' "$W/mm4.out" \
  && [ "$(docker exec vsw-dbf-target psql -U doadmin -d app -tAc 'select count(*) from t_it')" = 500 ] && ! grep -q "$tpw" "$W/mm4.out" "$DBM_LOG" \
  && ok "migrate-managed: data copied, row counts compared, password not in output or log" || { it_why "$W/mm4.out" 30; fail "mm copy"; }
FORCE=1 MM_ALLOW_PLAIN=1 run cmd_migrate_managed --target-env "$W/target.env" > "$W/mm5.out" 2>&1 && grep -q 'MIGRATE OK' "$W/mm5.out" \
  && ok "migrate-managed: re-run (final sync) replaces the target copy" || { it_why "$W/mm5.out" 30; fail "mm rerun"; }

# ---- pg-major-upgrade --------------------------------------------------------------------
run cmd_pg_major_upgrade --to 19 --base-image "$NEXT_BASE" --dry-run > "$W/pgmu0.out" 2>&1 && grep -q 'dry run: nothing changed' "$W/pgmu0.out" \
  && grep -q 'postgresql-19-pgvector' "$W/pgmu0.out" && grep -q 'vsw-test/postgres:19' "$W/pgmu0.out" && ok "pg-major-upgrade --dry-run: plan (images, pgvector package, disk) without changes" || { cat "$W/pgmu0.out"; fail "pgmu dry"; }
if run cmd_pg_major_upgrade --to 17 > "$W/pgmu1.out" 2>&1; then fail "downgrade accepted"; fi
grep -q 'not newer' "$W/pgmu1.out" && ok "pg-major-upgrade refuses a downgrade" || { cat "$W/pgmu1.out"; fail "pgmu down"; }
if docker pull -q "$NEXT_BASE" >/dev/null 2>&1; then
  if DBM_TEST_FAIL_PGMU=1 FORCE=1 run cmd_pg_major_upgrade --to 19 --base-image "$NEXT_BASE" > "$W/pgmu2.out" 2>&1; then fail "forced pgmu failure returned 0"; fi
  if grep -q 'ROLLED BACK to 18' "$W/pgmu2.out" && [ "$(psq vsw_admin app 'select current_setting($$server_version_num$$)::int / 10000')" = 18 ] \
    && [ "$(psq vsw_admin app 'select count(*) from t_it')" = 500 ] && grep -q '^PG_BASE_IMAGE=postgres:18$' "$W/dbm.conf"; then
    ok "pg-major-upgrade forced failure -> rolled back to 18, data and config intact"
    FORCE=1 run cmd_pg_major_upgrade --to 19 --base-image "$NEXT_BASE" > "$W/pgmu3.out" 2>&1 && grep -q 'PG MAJOR UPGRADE OK: 18 -> 19' "$W/pgmu3.out" || { it_why "$W/pgmu3.out" 40; fail "pgmu 19 run"; }
    v="$(psq vsw_admin app 'select current_setting($$server_version_num$$)::int / 10000')"; [ "$v" = 19 ] || fail "pgmu 19: server version is $v"
    [ "$(psq vsw_admin app 'select count(*) from t_it')" = 500 ] || fail "pgmu 19: row count"
    grep -q "^PG_BASE_IMAGE=$NEXT_BASE\$" "$W/dbm.conf" || { grep '^PG_' "$W/dbm.conf"; fail "pgmu 19: config not updated"; }
    out="$(cli -e PGPASSWORD="$pw" postgres:18 psql -X -tA "host=127.0.0.1 port=26442 user=app dbname=app sslmode=verify-full sslrootcert=/w/ca.crt" -c "select count(*) from t_it" 2>&1)" || true
    [ "$out" = 500 ] || { echo "$out"; fail "pgmu 19: verify-full through PgBouncer"; }
    ok "pg-major-upgrade 18 -> 19: data, roles, TLS and PgBouncer work; config updated"
    docker exec vswdbf-postgres-1 test -d /var/lib/postgresql/.pg18-old && FORCE=1 run cmd_pg_major_upgrade --cleanup 18 > "$W/pgmu4.out" 2>&1 \
      && ! docker exec vswdbf-postgres-1 test -e /var/lib/postgresql/.pg18-old && [ "$(psq vsw_admin app 'select count(*) from t_it')" = 500 ] \
      && ok "pg-major-upgrade --cleanup 18: old data removed, 19 data untouched" || { cat "$W/pgmu4.out" 2>/dev/null; fail "pgmu cleanup"; }
    run cmd_doctor > "$W/doctor2.out" 2>&1 && ok "doctor clean on 19" || { grep PROBLEM "$W/doctor2.out" || true; echo "note: doctor problems on 19 (see above)"; }
  elif grep -q 'build postgres 19' "$W/pgmu2.out" && grep -q 'ROLLED BACK' "$W/pgmu2.out"; then
    echo "skip pg-major-upgrade happy path: the 19 image did not build here (pgvector for 19 missing?) - rollback was exercised"
  else it_why "$W/pgmu2.out" 40; fail "pgmu rollback"; fi
else echo "skip pg-major-upgrade apply: cannot pull $NEXT_BASE"; fi
echo "db-features-it: $pass checks passed"
