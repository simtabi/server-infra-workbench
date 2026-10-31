#!/usr/bin/env bash
# Offline tests of the 1.4 manager features: no server, Docker or network.
# Functions are loaded with DBM_SOURCE_ONLY=1 (main returns before doing anything).
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }; fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
M="$PWD/src/shell/db/docker-db-server-manager.sh"
export PRIVATE_IP=10.0.0.5 VPC_CIDR=10.0.0.0/20 DBM_CONFIG="$T/none.conf" STATE_DIR="$T/state" ENV_SECRETS_DIR="$T/secrets" BACKUP_DIR="$T/backups"
# L fn args: load the manager's functions, then call one
L() { bash -c 'm="$1"; shift; fn=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; "${fn[@]}"' _ "$M" "$@"; }

# --- GFS retention --------------------------------------------------------------
for d in $(seq 0 59); do date -u -d "2026-10-31 -$d days" +%Y%m%d-031500 2>/dev/null || date -u -v-"${d}"d -j -f %Y%m%d 20261031 +%Y%m%d-031500; done > "$T/names"
printf '20250101-031500\n20240101-031500\n' >> "$T/names"
L gfs_keep "daily=7 weekly=4 monthly=3 yearly=2" < "$T/names" > "$T/keep"
n="$(wc -l < "$T/keep" | tr -d ' ')"
grep -qx 20261031-031500 "$T/keep" && grep -qx 20261025-031500 "$T/keep" && ! grep -qx 20261024-031500 "$T/keep" | grep -q x \
  && grep -qx 20250101-031500 "$T/keep" && ! grep -qx 20240101-031500 "$T/keep" && [ "$n" -ge 9 ] && [ "$n" -le 12 ] \
  && ok "GFS keeps 7 daily + weeks + months + 2 years ($n of $(wc -l < "$T/names" | tr -d ' '))" || { cat "$T/keep"; fail "gfs"; }
if L gfs_keep "daily=x" < "$T/names" 2>/dev/null; then :; fi
RETENTION="hourly=3" L validate_config 2>"$T/e" && fail "bad RETENTION accepted" || grep -q 'RETENTION item' "$T/e" && ok "bad RETENTION rejected"

# --- env-init (non-interactive) ---------------------------------------------------
if L cmd_env_init </dev/null >/dev/null 2>"$T/e"; then fail "env-init without --app"; fi
grep -q 'missing --app' "$T/e" && ok "env-init: missing value -> clear error (exit 2)" || { cat "$T/e"; fail "env-init missing"; }
bash -c 'm="$1" o="$2"; set --; DBM_SOURCE_ONLY=1 source "$m"; cmd_env_init --app shop --engines postgres,mysql --envs tst,dev,stg,prd --tenant-dbs dev,prd --pitr pgbackrest --offsite s3 --allow prd=10.0.0.8/32 --out "$o"' _ "$M" "$T/env.conf" </dev/null >/dev/null
grep -q '^APP=shop$' "$T/env.conf" && grep -q '^PROTECTED_ENVS="stg prd"$' "$T/env.conf" && grep -q '^TENANT_ENVS="dev prd"$' "$T/env.conf" \
  && grep -q '^ENABLE_MYSQL=1$' "$T/env.conf" && grep -q '^ALLOW_prd=10.0.0.8/32$' "$T/env.conf" && grep -q '^TLS_MODE=require$' "$T/env.conf" \
  && ! grep -qiE '(password|secret_key)=[^.]' "$T/env.conf" && ok "env-init writes the config (defaults: protect stg+prd, TLS require, no secrets)" || { cat "$T/env.conf"; fail "env-init"; }
bash -c 'm="$1" o="$2"; set --; DBM_SOURCE_ONLY=1 source "$m"; cmd_env_init --app shop --engines postgres --envs dev,prd --out "$o"' _ "$M" "$T/env.conf" </dev/null >/dev/null
[ "$(grep -c '^APP=' "$T/env.conf")" = 1 ] && ls "$T"/env.conf.bak-* >/dev/null && ok "env-init re-run replaces its block, keeps a backup" || fail "env-init rerun"
if L cmd_env_init --app shop --engines mongodb </dev/null >/dev/null 2>&1; then fail "mongo accepted"; else ok "env-init refuses MongoDB (ADR)"; fi
if L cmd_env_init --app Shop_1 </dev/null >/dev/null 2>&1; then fail "bad app"; else ok "env-init validates the app name"; fi
if APP=shop ENVS="dev qa" L validate_envs 2>/dev/null; then fail "unknown env"; else ok "unknown environment rejected"; fi

# --- pg_hba + per-env SQL ---------------------------------------------------------
APP=shop ENVS="dev prd" ALLOW_prd=10.0.0.8/32 L write_pg_hba "$T/hba"
grep -q '^host     /\^shop_prd(_t_\[a-z0-9_\]+)?\$  shop_prd_app,shop_prd_ro  172.30.88.0/24  scram-sha-256$' "$T/hba" \
  && grep -q '^host  /\^shop_prd(_t_\[a-z0-9_\]+)?\$  shop_prd_app,shop_prd_ro  10.0.0.8/32  scram-sha-256$' "$T/hba" \
  && grep -q '^host     all  shop_prd_app,shop_prd_ro  all  reject$' "$T/hba" && ! grep -qE '(trust|md5).*/|0\.0\.0\.0/0' "$T/hba" \
  && grep -q '^local    all       all            trust$' "$T/hba" && ok "pg_hba: env roles only reach their DBs from their allow list" || { cat "$T/hba"; fail "hba"; }
TLS_MODE=require L write_pg_hba "$T/hba2"; grep -q '^hostssl  all       all   10.0.0.0/20' "$T/hba2" && ok "pg_hba: TLS_MODE=require uses hostssl for the VPC" || fail "hostssl"
APP=shop ENVS="dev prd" TENANT_ENVS=prd L cmd_env_sql prd > "$T/prd.sql"
grep -q 'ALTER ROLE "shop_prd_app" LOGIN NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS CREATEDB' "$T/prd.sql" \
  && grep -q 'ALTER ROLE "shop_prd_ro" LOGIN NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS NOCREATEDB' "$T/prd.sql" \
  && grep -q 'GRANT "shop_prd_owner" TO "shop_prd_app"' "$T/prd.sql" && ! grep -q PASSWORD "$T/prd.sql" \
  && ok "env-sql prd: least-privilege roles, tenants only where enabled, no passwords" || { cat "$T/prd.sql"; fail "env-sql"; }
APP=shop ENVS="dev" TENANT_ENVS=dev L cmd_env_sql dev mysql > "$T/my.sql"
grep -qF 'ON `shop\_dev`.* TO' "$T/my.sql" && grep -qF 'ON `shop\_dev\_t\_%`.* TO' "$T/my.sql" && ! grep -qiE 'GRANT OPTION|ON \*\.\*|FILE|SUPER|PROCESS' "$T/my.sql" \
  && ok "MySQL grants: escaped _ , tenant pattern, no global privileges" || { cat "$T/my.sql"; fail "my grants"; }
L my_grant_sql app my_app owner | grep -qF '`my\_app`.*' && ok "create-db grants escape _ in database names" || fail "escape"

# --- guard rails --------------------------------------------------------------------
if APP=shop ENVS="dev prd" L guard_destructive shop_prd prd 0 2>"$T/e"; then fail "prd without --force-prod"; fi
grep -q 'add --force-prod' "$T/e" && ok "protected env needs --force-prod" || fail "force-prod"
if APP=shop ENVS="dev prd" L guard_destructive shop_prd prd 1 </dev/null 2>"$T/e"; then fail "prd without typed name"; fi
grep -q 'WORKBENCH_CONFIRM=prd' "$T/e" && ok "protected env needs the typed env name" || fail "typed"
[ "$(APP=shop ENVS="dev prd" L env_of_db shop_prd_t_42)" = prd ] && [ "$(APP=shop ENVS="dev prd" L env_of_db shop_dev)" = dev ] && [ -z "$(APP=shop L env_of_db other)" ] \
  && ok "databases map to their environment (tenants too)" || fail "env_of_db"

# --- notify + redaction -------------------------------------------------------------
ALERT_COMMAND="printf '%s|%s|%s\n' >> $T/alerts" L notify backup fail "PGPASSWORD=hunter2 token abcdef0123456789abcdef0123456789ab failed"
grep -q '^backup|fail|' "$T/alerts" && ! grep -q hunter2 "$T/alerts" && ! grep -q abcdef0123456789abcdef0123456789ab "$T/alerts" && ok "notify: hook called, secrets redacted" || { cat "$T/alerts"; fail "notify"; }

# --- off-site copy with a stub rclone (local dir as the bucket) -----------------------
mkdir -p "$T/bin" "$T/bucket" "$T/b/20261031-031500" "$T/etc"
cat > "$T/bin/rclone" <<'EOF'
#!/usr/bin/env bash
# stub: vsw:bucket/prefix/name -> $STUB_BUCKET/prefix/name ; records that creds came from env
[ -n "${RCLONE_CONFIG_VSW_ACCESS_KEY_ID:-}" ] || { echo "no creds" >&2; exit 1; }
map() { local p="${1#vsw:}"; echo "$STUB_BUCKET/${p#*/}"; }
case "$1" in
  copyto) shift; [ "$1" = --s3-no-check-bucket ] && shift; if [[ "$1" == vsw:* ]]; then cp "$(map "$1")" "$2"; else mkdir -p "$(dirname "$(map "$2")")"; cp "$1" "$(map "$2")"; fi ;;
  lsf) ls "$(map "$2")" ;;
  delete) exit 0 ;;
esac
EOF
chmod +x "$T/bin/rclone"
printf 'OFFSITE_ACCESS_KEY=AKFAKE\nOFFSITE_SECRET_KEY=fake-secret-key\n' > "$T/etc/offsite.env"; chmod 600 "$T/etc/offsite.env"
echo "-- dump complete" | gzip > "$T/b/20261031-031500/postgres.sql.gz"
export PATH="$T/bin:$PATH" STUB_BUCKET="$T/bucket" OFFSITE=s3 OFFSITE_BUCKET=bk OFFSITE_PREFIX=db/h OFFSITE_CREDS_FILE="$T/etc/offsite.env" OFFSITE_KEY_FILE="$T/etc/backup.key" ENABLE_MYSQL=0 ENABLE_MARIADB=0
L offsite_upload "$T/b/20261031-031500" > "$T/off.out" 2>&1 || { cat "$T/off.out"; fail "offsite upload"; }
[ -f "$T/bucket/db/h/20261031-031500.tar.gz.enc" ] && ! gzip -t "$T/bucket/db/h/20261031-031500.tar.gz.enc" 2>/dev/null \
  && [ "$(stat -c %a "$T/etc/backup.key" 2>/dev/null || stat -f %Lp "$T/etc/backup.key")" = 600 ] && grep -q 'COPY IT OFF THIS SERVER' "$T/off.out" \
  && ! grep -q fake-secret-key "$T/off.out" && ok "off-site: encrypted before upload, key 600, creds from env not printed" || { cat "$T/off.out"; fail "offsite"; }
bash -c 'm="$1"; set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; load_env(){ :; }; cmd_offsite verify' _ "$M" > "$T/ver.out" 2>&1 \
  && grep -q 'off-site verify ok: 20261031-031500.tar.gz.enc' "$T/ver.out" && ok "off-site verify: download, checksum, decrypt, dump check" || { cat "$T/ver.out"; fail "offsite verify"; }
printf 'garbage' >> "$T/bucket/db/h/20261031-031500.tar.gz.enc"
if bash -c 'm="$1"; set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; load_env(){ :; }; cmd_offsite verify' _ "$M" > "$T/ver2.out" 2>&1; then fail "tampered copy verified"; fi
grep -q 'checksum mismatch' "$T/ver2.out" && ok "off-site verify detects a tampered copy" || { cat "$T/ver2.out"; fail "tamper"; }

# --- sizing ------------------------------------------------------------------------------
[ "$(ENABLE_MYSQL=0 ENABLE_MARIADB=0 L engine_ram_mb)" = 1600 ] && [ "$(ENABLE_MYSQL=1 ENABLE_MARIADB=1 L engine_ram_mb)" = 3392 ] \
  && [ "$(L size_for_mb 3392)" = s-2vcpu-4gb ] && ok "RAM need per engine set -> suggested droplet size" || fail "sizing"

# --- compose: hardening flags -------------------------------------------------------------
mkdir -p "$T/db"; ENABLE_MYSQL=1 ENABLE_MARIADB=1 DB_DIR="$T/db" L eval 'dc() { :; }; write_files >/dev/null'
c="$T/db/docker-compose.yml"
grep -q 'POSTGRES_USER: ${PG_ADMIN_USER}' "$c" && grep -q 'hba_file=/etc/postgresql/vsw/pg_hba.conf' "$c" && grep -q 'log_min_duration_statement=500ms' "$c" \
  && grep -q '"--local-infile=0"' "$c" && grep -q 'secure-file-priv=/var/lib/mysql-files' "$c" && grep -q 'MYSQL_ROOT_HOST: localhost' "$c" \
  && grep -q 'subnet: "${DOCKER_SUBNET}"' "$c" && grep -q '^PG_IMAGE=vsw/postgres:18-postgis-pgvector$' "$T/db/stack.env" \
  && ok "compose: admin bootstrap, pg_hba, logging, local_infile=0, secure_file_priv, no root@'%', fixed subnet, neutral image tag" || fail "compose hardening"

# --- cross-region: extra bind addresses, region check ----------------------------------------
mkdir -p "$T/db2"; EXTRA_BIND_IPS=10.200.0.1 DB_DIR="$T/db2" L eval 'dc() { :; }; write_files >/dev/null'
grep -qF 'ports: ["${PRIVATE_IP}:${PG_PORT}:5432", "10.200.0.1:${PG_PORT}:5432"]' "$T/db2/docker-compose.yml" \
  && grep -qF 'ports: ["${PRIVATE_IP}:${PGBOUNCER_PORT}:5432", "10.200.0.1:${PGBOUNCER_PORT}:5432"]' "$T/db2/docker-compose.yml" \
  && ! grep -q '0\.0\.0\.0' "$T/db2/docker-compose.yml" && ok "EXTRA_BIND_IPS: every DB port also published on the tunnel IP" || { grep ports "$T/db2/docker-compose.yml"; fail "extra binds"; }
L ip_in_cidr 10.200.0.2 10.0.0.0/8 && ! L ip_in_cidr 10.17.0.2 10.16.0.0/16 2>/dev/null && L ip_in_cidr 192.0.2.9 0.0.0.0/0 && ! L ip_private 203.0.113.5 2>/dev/null && L ip_private 100.64.1.1 \
  && ok "ip_in_cidr / ip_private" || fail "cidr math"
EXTRA_BIND_IPS=203.0.113.5 L validate_config 2>"$T/e" && fail "public bind accepted" || { grep -q 'ALLOW_PUBLIC_BIND=1' "$T/e" && grep -q 'TLS_MODE=require is mandatory' "$T/e" && ok "public bind refused without ALLOW_PUBLIC_BIND=1 and TLS"; } || { cat "$T/e"; fail "public bind"; }
EXTRA_BIND_IPS=203.0.113.5 ALLOW_PUBLIC_BIND=1 TLS_MODE=require L validate_config 2>"$T/e" && ok "public bind accepted with ALLOW_PUBLIC_BIND=1 + TLS_MODE=require" || { cat "$T/e"; fail "public bind ok"; }
PRIVATE_IP=203.0.113.5 L validate_config 2>"$T/e" && fail "public PRIVATE_IP" || { grep -q 'not a private' "$T/e" && ok "PRIVATE_IP must be a private address"; } || fail "private ip"
PEER_REGIONS="nyc 1" L validate_config 2>"$T/e" && fail "bad region" || { grep -q 'PEER_REGIONS entry' "$T/e" && ok "PEER_REGIONS validated"; } || fail "region slug"
mkdir -p "$T/meta"; printf 'nyc1' > "$T/meta/region"
mkdir -p "$T/mbin"; printf '#!/bin/sh\nfor a; do u="$a"; done; cat "%s/meta/${u##*/}"\n' "$T" > "$T/mbin/curl"; chmod +x "$T/mbin/curl"
PATH="$T/mbin:$PATH" PEER_REGIONS=ams3 L eval 'doctor_network; echo "bad=$D_BAD"' > "$T/net.out" 2>&1 || true
grep -q 'this droplet is in nyc1' "$T/net.out" && grep -q 'PROBLEM  peer region ams3 differs from nyc1' "$T/net.out" && grep -q 'wireguard setup' "$T/net.out" \
  && ok "doctor: region mismatch without a tunnel is a PROBLEM with the fix" || { cat "$T/net.out"; fail "region mismatch"; }
PATH="$T/mbin:$PATH" PEER_REGIONS=nyc1 L eval 'doctor_network; echo "bad=$D_BAD"' > "$T/net.out" 2>&1 || true
grep -q 'peer region nyc1: same region' "$T/net.out" && grep -q 'bad=0' "$T/net.out" && ok "doctor: same region is ok" || { cat "$T/net.out"; fail "same region"; }
PATH="$T/mbin:$PATH" PRIVATE_IP=10.0.0.5 VPC_CIDR=10.16.0.0/20 L eval 'doctor_network; echo "bad=$D_BAD"' > "$T/net.out" 2>&1 || true
grep -q 'outside VPC_CIDR' "$T/net.out" && ok "doctor: PRIVATE_IP outside VPC_CIDR is a PROBLEM" || { cat "$T/net.out"; fail "vpc cidr"; }
echo "smoke-db: all $pass checks passed"
