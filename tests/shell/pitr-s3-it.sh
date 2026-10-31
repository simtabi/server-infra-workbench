#!/usr/bin/env bash
# Integration test of point-in-time recovery to an S3 repository (`make it`): the Garage add-on
# (addon.sh, bucket + least-privilege key) behind a TLS front (Caddy, a CA generated per run),
# PITR=pgbackrest with PITR_REPO_TYPE=s3, path-style URLs, a private CA and an explicit port.
# setup -> rows before T -> rows after T -> restore --target T -> only the rows before T.
# WHY: production PITR goes to DigitalOcean Spaces; the posix test (pitr-it) cannot prove the S3
# options (endpoint, port, uri style, region, CA, keys in pitr.env) that Spaces depends on.
# Spaces differs only in: host-style URLs (PITR_S3_URI_STYLE=host), a public CA (no PITR_S3_CA_FILE),
# OFFSITE_ENDPOINT=https://<region>.digitaloceanspaces.com, OFFSITE_REGION=us-east-1.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "pitr-s3-it skipped (no docker)"; exit 0; }
M="$PWD/src/shell/db/docker-db-server-manager.sh"; A="$PWD/src/shell/addons/addon.sh"
CADDY_IMAGE="$(sed -n 's/.*CADDY_IMAGE:-\([^}]*\)}.*/\1/p' stacks/caddy/docker-compose.yml | head -1)"
W="$(mktemp -d /tmp/vsw-pitrs3.XXXX)"; D="$W/vswpitrs3"; S3NET=vsw_pitrs3_s3; FRONT=vsw-pitrs3-tls; HOSTNAME_S3=s3.vsw.test
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { rm -rf /tmp/vsw-pitrs3-last; mkdir -p /tmp/vsw-pitrs3-last; cp "$W"/*.out "$W/run.log" /tmp/vsw-pitrs3-last/ 2>/dev/null || true
  [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
  docker rm -f "$FRONT" >/dev/null 2>&1 || true; docker ps -aq --filter name=vsw-rt- | xargs -r docker rm -f >/dev/null 2>&1 || true
  it_purge vswpitrs3 vsw-garage; it_rm_net "$S3NET"; rm -rf "$W"; }
trap cleanup EXIT
[ "${IT_KEEP:-0}" = 1 ] && trap 'echo "kept: $W"' EXIT

# ---- 1. Garage (the add-on, as on a server) -----------------------------------------------
printf 'ADDONS_DIR=%s\nAUDIT_LOG=%s\nADDON_BIND=127.0.0.1\nADDON_NETWORK=bridge\nGARAGE_S3_PORT=24900\nGARAGE_ADMIN_PORT=24903\nSTORAGE_BUCKET=pitr\n' \
  "$W/root" "$W/audit.log" > "$W/addons.conf"
export ADDON_CONF="$W/addons.conf" ADDON_ALLOW_NONROOT=1
"$A" install garage --role web --yes > "$W/garage.out" 2>&1 && ok "garage add-on: bucket 'pitr' + bucket-scoped key" || { tail -30 "$W/garage.out"; fail "garage install"; }
"$A" laravel-env garage --out "$W/garage.env" > /dev/null 2>&1
kv() { sed -n "s/^$1=//p" "$W/garage.env"; }
gc="$(docker ps -q --filter label=com.docker.compose.project=vsw-garage --filter label=com.docker.compose.service=garage | head -1)"
[ -n "$gc" ] || fail "garage container not found"

# ---- 2. TLS in front (pgBackRest speaks HTTPS only); a CA generated for this run -------------
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=vsw-it-ca" -keyout "$W/ca.key" -out "$W/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=$HOSTNAME_S3" -keyout "$W/srv.key" -out "$W/srv.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\n' "$HOSTNAME_S3" > "$W/san.ext"
openssl x509 -req -in "$W/srv.csr" -CA "$W/ca.crt" -CAkey "$W/ca.key" -CAcreateserial -days 2 -extfile "$W/san.ext" -out "$W/srv.crt" >/dev/null 2>&1
chmod 644 "$W/srv.key" "$W/srv.crt"   # read by the caddy user inside its container; a throwaway key
printf '{\n\tauto_https off\n\tadmin off\n}\nhttps://%s:8443 {\n\ttls /certs/srv.crt /certs/srv.key\n\treverse_proxy garage:3900\n}\n' "$HOSTNAME_S3" > "$W/Caddyfile"
docker network create "$S3NET" >/dev/null
docker network connect --alias garage "$S3NET" "$gc"
docker run -d --name "$FRONT" --network "$S3NET" -v "$W/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$W/srv.crt:/certs/srv.crt:ro" \
  -v "$W/srv.key:/certs/srv.key:ro" "$CADDY_IMAGE" >/dev/null && ok "TLS front ($CADDY_IMAGE) with a CA generated for this run" || fail "caddy"

# ---- 3. the DB stack with an S3 PITR repository ---------------------------------------------
umask 077
{ echo "OFFSITE_ACCESS_KEY=$(kv AWS_ACCESS_KEY_ID)"; echo "OFFSITE_SECRET_KEY=$(kv AWS_SECRET_ACCESS_KEY)"; echo "PITR_CIPHER_PASS=$(openssl rand -hex 32)"; } > "$W/offsite.env"
umask 022
REGION="$(kv AWS_DEFAULT_REGION)"
printf 'PG_BASE_IMAGE=postgres:18\nPG_IMAGE=vsw-test/postgres:18\n' > "$W/dbm.conf"; chmod 600 "$W/dbm.conf"
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$W/dbm.conf" \
  DBM_LOCK="$W/lock" DBM_LOG="$W/run.log" BACKUP_DIR="$W/backups" MIN_FREE_MB=10 \
  STATE_DIR="$W/state" ENV_SECRETS_DIR="$W/secrets" OFFSITE_CREDS_FILE="$W/offsite.env" \
  DOCKER_SUBNET=172.30.95.0/24 DOCKER_NETWORK=vsw_pitrs3 \
  ENABLE_MYSQL=0 ENABLE_MARIADB=0 ENABLE_ADMINER=0 PG_PORT=25471 PGBOUNCER_PORT=26471 \
  PG_EXTENSIONS="pg_trgm" PG_USER=app PG_DB=app PITR=pgbackrest PITR_REPO_TYPE=s3 \
  OFFSITE_ENDPOINT="https://$HOSTNAME_S3:8443" OFFSITE_BUCKET=pitr OFFSITE_REGION="$REGION" \
  PITR_S3_URI_STYLE=path PITR_S3_CA_FILE="$W/ca.crt" PITR_REPO_PATH=/db-main
run()  { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }
dcx()  { (cd "$D" && docker compose --env-file .env --env-file stack.env "$@"); }
psq()  { dcx exec -T postgres psql -X -tA -U vsw_admin -d app -c "$1"; }
archived() { local w _; w="$(psq 'select pg_walfile_name(pg_switch_wal())')"
  for _ in $(seq 1 60); do [ "$(psq "select coalesce(last_archived_wal >= '$w', false) from pg_stat_archiver")" = t ] && return 0; sleep 1; done; return 1; }

if OFFSITE_ENDPOINT="http://$HOSTNAME_S3:8443" run validate_config > "$W/v.out" 2>&1; then fail "http:// endpoint accepted for an S3 PITR repo"; fi
grep -q 'HTTPS only' "$W/v.out" && ok "validate: an http:// S3 endpoint is refused (pgBackRest speaks HTTPS only)" || { cat "$W/v.out"; fail "http refusal"; }

run cmd_install > "$W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$W/install.out" && ok "install with PITR=pgbackrest, s3 repo" || { tail -40 "$W/install.out"; fail "install"; }
conf="$D/postgres/conf/pgbackrest.conf"
grep -qx 'repo1-s3-endpoint=s3.vsw.test' "$conf" && grep -qx 'repo1-storage-port=8443' "$conf" && grep -qx 'repo1-s3-uri-style=path' "$conf" \
  && grep -qx 'repo1-storage-ca-file=/etc/postgresql/vsw/s3-ca.crt' "$conf" && ok "pgbackrest.conf: endpoint, port, path style, CA" || { cat "$conf"; fail "pgbackrest.conf"; }
sk="$(kv AWS_SECRET_ACCESS_KEY)"
! grep -qF "$sk" "$conf" && grep -qF "$sk" "$D/postgres/pitr.env" && [ "$(stat -c %a "$D/postgres/pitr.env" 2>/dev/null || stat -f %Lp "$D/postgres/pitr.env")" = 600 ] \
  && ok "S3 secret only in postgres/pitr.env (600), not in pgbackrest.conf" || fail "secret placement"
docker network connect --alias "$HOSTNAME_S3" "$DOCKER_NETWORK" "$FRONT"

run cmd_pitr setup > "$W/setup.out" 2>&1 && grep -q 'PITR ready' "$W/setup.out" && ok "pitr setup over S3: stanza + full backup" || { tail -40 "$W/setup.out"; fail "pitr setup"; }
! cat "$W"/*.out "$W/run.log" 2>/dev/null | grep -qF "$sk" && ok "the S3 secret is never printed or logged" || fail "secret printed"
psq 'create table t_pitr (id int primary key); insert into t_pitr select generate_series(1, 100)' >/dev/null
archived || fail "WAL before T not archived"
sleep 2; T="$(psq "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00'")"; sleep 2
psq 'insert into t_pitr select generate_series(101, 150); delete from t_pitr where id <= 10' >/dev/null
archived || fail "WAL after T not archived"
ok "WAL archived to S3 before and after T"

# the objects really are in the bucket, and encrypted (pgBackRest cipher), read with the app key
s3get() { printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:%s:s3"\n' "$(kv AWS_ACCESS_KEY_ID)" "$sk" "$(kv AWS_DEFAULT_REGION)" \
  | curl -s -o "$W/obj" -w '%{http_code}' -K - "http://127.0.0.1:24900/pitr$1"; }
[ "$(s3get '?list-type=2&prefix=db-main/archive/main/')" = 200 ] && grep -q '<Key>db-main/archive/main/' "$W/obj" \
  && ok "bucket holds the WAL archive under PITR_REPO_PATH" || { head -c 400 "$W/obj"; fail "bucket listing"; }
[ "$(s3get /db-main/backup/main/backup.info)" = 200 ] && ! grep -q '^\[backrest\]' "$W/obj" \
  && ok "repository files are encrypted at rest (no plaintext backup.info)" || fail "backup.info plaintext or missing"

WORKBENCH_CONFIRM=prd FORCE=1 run cmd_pitr restore --target "$T" --force-prod </dev/null > "$W/restore.out" 2>&1 && grep -q 'PITR restore done' "$W/restore.out" || { tail -40 "$W/restore.out"; fail "pitr restore"; }
n="$(psq 'select count(*) || '"' '"' || min(id) || '"' '"' || max(id) from t_pitr')"
[ "$n" = "100 1 100" ] && ok "restore from S3 --target T: exactly the 100 rows from before T" || fail "after restore: $n (want 100 1 100)"
run cmd_verify > "$W/verify.out" 2>&1 && [ "$(psq 'select pg_is_in_recovery()')" = f ] && ok "verify after restore; promoted and writable" || { tail -20 "$W/verify.out"; fail "verify"; }
run cmd_pitr backup diff > "$W/diff.out" 2>&1 && ok "pitr backup diff on the new timeline" || { tail -20 "$W/diff.out"; fail "diff after restore"; }
echo "pitr-s3-it: $pass checks passed"
