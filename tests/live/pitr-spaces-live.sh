#!/usr/bin/env bash
# Live test: Postgres point-in-time restore against real DigitalOcean Spaces (make live-test).
# Creates a throwaway Spaces bucket and two throwaway Spaces keys (a full-access one that only
# creates and deletes the bucket, and a key scoped to that bucket that the stack uses), runs the
# DB stack in Docker on this machine with PITR=pgbackrest, PITR_REPO_TYPE=s3 and the Spaces
# settings (host-style URLs, public CA, region us-east-1), restores to a point in time, then
# deletes every object, the bucket and both keys, and checks that none is left.
# WHY: pitr-s3-it proves the S3 options against Garage; only Spaces itself proves host-style
# addressing, the real endpoint and its public CA, and a bucket-scoped key's permissions.
# COST: the first bucket starts the Spaces subscription ($5/month, prorated hourly) and deleting
# the last bucket ends it, so a run costs about a cent when no other bucket exists.
# Dry run by default; --yes spends. See docs/live-tests.md.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/live/lib/live.sh
. tests/live/lib/live.sh
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
LIVE_TIMEOUT_MIN=30 LIVE_MAX_USD=0.50
live_args "$@"
SP_REGION="${SPACES_REGION:-nyc3}"
[[ "$SP_REGION" =~ ^[a-z]{3}[0-9]$ ]] || live_die "bad SPACES_REGION"
SP_HOST="$SP_REGION.digitaloceanspaces.com"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || live_die "needs Docker on this machine"
# Spaces: $5/month prorated hourly while a bucket exists (~$0.007/h): budget one hour, rounded up
live_begin pitr-spaces 0 0.01
echo "   Spaces region $SP_REGION: 1 bucket + 2 keys, deleted at the end"

B="$LIVE_NP"   # bucket names are global: the run id makes it unique
D="$LIVE_W/vswlivepitr"
umask 077
# shellcheck source=tests/live/lib/spaces.sh
. tests/live/lib/spaces.sh
SP_W="$LIVE_W"
s3() { sp_s3 "$@"; }
key_create() { sp_key_create "$@"; }

spaces_cleanup() {
  local rc=0 code k n
  [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
  docker ps -aq --filter name=vsw-rt- | xargs -r docker rm -f >/dev/null 2>&1 || true
  it_purge vswlivepitr
  [ -f "$LIVE_W/app.env" ] && { sp_key_delete "$LIVE_W/app.env" || { echo "!! could not delete the scoped key" >&2; rc=1; }; }
  if [ -f "$LIVE_W/admin.env" ]; then
    sp_bucket_purge "$LIVE_W/admin.env" "$SP_REGION" "$B" && echo "bucket $B deleted" || { echo "!! bucket $B still there" >&2; rc=1; }
    # any bucket left in the account keeps the Spaces subscription (and its $5/month) running.
    # The listing lags a deletion by a few seconds, so wait for $B to drop out of it.
    for _ in $(seq 1 24); do sp_buckets "$LIVE_W/admin.env" "$SP_REGION" > "$LIVE_W/buckets" || break
      grep -qx "$B" "$LIVE_W/buckets" || break; sleep 5; done
    if grep -qx "$B" "$LIVE_W/buckets" 2>/dev/null; then echo "!! $B still listed" >&2; rc=1
    else n="$(grep -c . "$LIVE_W/buckets" || true)"
      echo "buckets left in $SP_REGION: $n$( [ "$n" = 0 ] && echo ' (no bucket: the Spaces subscription ends, billing stops)')"; fi
    sp_key_delete "$LIVE_W/admin.env" || { echo "!! could not delete the full-access key" >&2; rc=1; }
  fi
  n="$(doctl spaces keys list -o json 2>/dev/null | jq --arg p "$LIVE_NP" '[.[]? | select(.name | startswith($p))] | length')"
  [ "$n" = 0 ] && echo "Spaces keys verified: none named $LIVE_NP* left" || { echo "!! $n Spaces key(s) left" >&2; rc=1; }
  return "$rc"
}
LIVE_CLEANUP_HOOKS+=(spaces_cleanup)

# ---- 1. bucket + keys ------------------------------------------------------------------------
key_create "$LIVE_NP-admin" 'bucket=;permission=fullaccess' "$LIVE_W/admin.env" && live_ok "throwaway full-access key (creates and deletes the bucket only)" || live_fail "admin key"
code=000; for _ in $(seq 1 12); do code="$(s3 "$LIVE_W/admin.env" PUT "https://$SP_HOST/$B")"; [ "$code" = 200 ] && break; sleep 5; done   # new keys take a few seconds
[ "$code" = 200 ] && live_ok "bucket $B created in $SP_REGION" || { head -c 300 "$LIVE_W/s3.body"; live_fail "bucket create: HTTP $code"; }
key_create "$LIVE_NP-app" "bucket=$B;permission=readwrite" "$LIVE_W/app.env" && live_ok "throwaway key scoped to $B (readwrite)" || live_fail "scoped key"
for _ in $(seq 1 12); do [ "$(s3 "$LIVE_W/app.env" GET "https://$SP_HOST/$B?list-type=2")" = 200 ] && break; sleep 5; done
code="$(s3 "$LIVE_W/app.env" PUT "https://$SP_HOST/$LIVE_NP-other")"
[ "$code" = 403 ] && live_ok "the scoped key cannot create another bucket (403)" || { [ "$code" = 200 ] && s3 "$LIVE_W/admin.env" DELETE "https://$SP_HOST/$LIVE_NP-other" >/dev/null; live_fail "scoped key created a bucket (HTTP $code)"; }

# ---- 2. the DB stack with its PITR repository on Spaces ----------------------------------------
{ cat "$LIVE_W/app.env"; echo "PITR_CIPHER_PASS=$(openssl rand -hex 32)"; } > "$LIVE_W/offsite.env"
umask 022
M="$PWD/src/shell/db/docker-db-server-manager.sh"
printf 'PG_BASE_IMAGE=postgres:18\nPG_IMAGE=vsw-test/postgres:18\n' > "$LIVE_W/dbm.conf"; chmod 600 "$LIVE_W/dbm.conf"
export DOCTOR_DISK_WARN_PCT=100 DOCTOR_DISK_BAD_PCT=100
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$LIVE_W/dbm.conf" \
  DBM_LOCK="$LIVE_W/lock" DBM_LOG="$LIVE_W/run.log" BACKUP_DIR="$LIVE_W/backups" MIN_FREE_MB=10 \
  STATE_DIR="$LIVE_W/state" ENV_SECRETS_DIR="$LIVE_W/secrets" OFFSITE_CREDS_FILE="$LIVE_W/offsite.env" \
  DOCKER_SUBNET=172.30.91.0/24 DOCKER_NETWORK=vsw_livepitr \
  ENABLE_MYSQL=0 ENABLE_MARIADB=0 ENABLE_ADMINER=0 PG_PORT=25481 PGBOUNCER_PORT=26481 \
  PG_EXTENSIONS="pg_trgm" PG_USER=app PG_DB=app PITR=pgbackrest PITR_REPO_TYPE=s3 \
  OFFSITE_ENDPOINT="https://$SP_HOST" OFFSITE_BUCKET="$B" OFFSITE_REGION=us-east-1 \
  PITR_S3_URI_STYLE=host PITR_REPO_PATH=/db-main
unset PITR_S3_CA_FILE
run() { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }
dcx() { (cd "$D" && docker compose --env-file .env --env-file stack.env "$@"); }
psq() { dcx exec -T postgres psql -X -tA -U vsw_admin -d app -c "$1"; }
archived() { local w _; w="$(psq 'select pg_walfile_name(pg_switch_wal())')"
  for _ in $(seq 1 90); do [ "$(psq "select coalesce(last_archived_wal >= '$w', false) from pg_stat_archiver")" = t ] && return 0; sleep 1; done; return 1; }
why() { it_why "$1" "${2:-40}"; }

run cmd_install > "$LIVE_W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$LIVE_W/install.out" && live_ok "install with PITR=pgbackrest on Spaces" || { why "$LIVE_W/install.out"; live_fail "install"; }
conf="$D/postgres/conf/pgbackrest.conf"
grep -qx "repo1-s3-endpoint=$SP_HOST" "$conf" && grep -qx 'repo1-s3-uri-style=host' "$conf" && grep -qx "repo1-s3-bucket=$B" "$conf" \
  && ! grep -q 'repo1-storage-ca-file' "$conf" && live_ok "pgbackrest.conf: Spaces endpoint, host-style URLs, public CA" || { cat "$conf"; live_fail "pgbackrest.conf"; }
run cmd_pitr setup > "$LIVE_W/setup.out" 2>&1 && grep -q 'PITR ready' "$LIVE_W/setup.out" && live_ok "pitr setup on Spaces: stanza + full backup" || { why "$LIVE_W/setup.out"; live_fail "pitr setup"; }
psq 'create table t_pitr (id int primary key); insert into t_pitr select generate_series(1, 100)' >/dev/null
archived || live_fail "WAL before T not archived"
sleep 2; T="$(psq "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00'")"; sleep 2
psq 'insert into t_pitr select generate_series(101, 150); delete from t_pitr where id <= 10' >/dev/null
archived || live_fail "WAL after T not archived"
live_ok "WAL archived to Spaces before and after T"
[ "$(s3 "$LIVE_W/app.env" GET "https://$SP_HOST/$B?list-type=2&prefix=db-main/archive/main/")" = 200 ] && grep -q '<Key>db-main/archive/main/' "$LIVE_W/s3.body" \
  && live_ok "the bucket holds the WAL archive under PITR_REPO_PATH" || live_fail "bucket listing"
[ "$(s3 "$LIVE_W/app.env" GET "https://$SP_HOST/$B/db-main/backup/main/backup.info")" = 200 ] && ! grep -q '^\[backrest\]' "$LIVE_W/s3.body" \
  && live_ok "repository files are encrypted at rest on Spaces" || live_fail "backup.info plaintext or missing"
WORKBENCH_CONFIRM=prd FORCE=1 run cmd_pitr restore --target "$T" --force-prod </dev/null > "$LIVE_W/restore.out" 2>&1 && grep -q 'PITR restore done' "$LIVE_W/restore.out" || { why "$LIVE_W/restore.out"; live_fail "pitr restore"; }
n="$(psq 'select count(*) || '"' '"' || min(id) || '"' '"' || max(id) from t_pitr')"
[ "$n" = "100 1 100" ] && live_ok "restore from Spaces --target T: exactly the 100 rows from before T" || live_fail "after restore: $n (want 100 1 100)"
run cmd_verify > "$LIVE_W/verify.out" 2>&1 && [ "$(psq 'select pg_is_in_recovery()')" = f ] && live_ok "verify after restore; promoted and writable" || { why "$LIVE_W/verify.out" 20; live_fail "verify"; }
run cmd_pitr backup diff > "$LIVE_W/diff.out" 2>&1 && live_ok "pitr backup diff on the new timeline" || { why "$LIVE_W/diff.out" 20; live_fail "diff after restore"; }
leak=0; for v in "$(sed -n 's/^OFFSITE_SECRET_KEY=//p' "$LIVE_W/app.env")" "$(sed -n 's/^OFFSITE_SECRET_KEY=//p' "$LIVE_W/admin.env")" "$(sed -n 's/^PITR_CIPHER_PASS=//p' "$LIVE_W/offsite.env")"; do
  cat "$LIVE_W"/*.out "$LIVE_W/run.log" 2>/dev/null | grep -qF -- "$v" && leak=1; done
[ "$leak" = 0 ] && live_ok "no Spaces secret or cipher pass in any output or log" || live_fail "secret printed"
echo "pitr-spaces-live: $LIVE_PASS checks passed"
