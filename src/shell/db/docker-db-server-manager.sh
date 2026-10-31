#!/usr/bin/env bash
# =============================================================================
#  Docker DB Server Setup Manager            (docker-db-server-manager.sh)
# =============================================================================
#  PURPOSE
#    Builds, resets, checks, backs up and restores the Docker database stack on
#    a dedicated DB droplet (DigitalOcean, Ubuntu): PostgreSQL 18 + PostGIS 3.6 +
#    pgvector, PgBouncer 1.26.1 (session mode), MySQL 9.7 and MariaDB 13.
#    Every port is bound to the droplet's PRIVATE IP only. Least privilege: one admin
#    superuser, non-superuser app logins, no root@'%', per-environment databases and
#    roles, guard rails for protected environments, GFS/off-site/PITR backups with
#    restore tests, and a doctor that checks all of it.
#
#  REQUIREMENTS
#    - Ubuntu/Debian, run as root, outbound internet (Docker Hub, apt.postgresql.org)
#    - Docker Engine + compose plugin (installed automatically if missing)
#    - Private VPC interface eth1 (e.g. 10.0.0.5 in 10.0.0.0/20)
#    - ufw optional (rules are skipped with a warning if it is missing)
#
#  LAYOUT ($DB_DIR, default /opt/db)
#    .env                         PRIVATE_IP + generated passwords (chmod 600)
#    stack.env                    non-secret settings (users, images, ports), rewritten each run
#    docker-compose.yml           all four services
#    postgres/Dockerfile          postgis/postgis:18-3.6 + postgresql-18-pgvector
#    postgres/init/10-extensions.sql   extensions for template1 + $PG_DB
#    backups/<timestamp>/         output of `backup` (postgres.sql.gz, mysql.sql.gz, mariadb.sql.gz)
#    Docker volumes: db_pg_data, db_mysql_data, db_mariadb_data
#
#  COMMANDS
#    See `help` (usage below) and docs/tools/db-server-manager.md.
#
#  CONFIGURATION
#    Settings come from (highest wins): environment variables, then the config
#    file (--config FILE, DBM_CONFIG, or /etc/docker-db-server-manager.conf),
#    then the defaults below. See config/db-server.env.example.
#
#  ENGINES
#    ENABLE_POSTGRES ENABLE_PGBOUNCER ENABLE_MYSQL ENABLE_MARIADB (1/0, default 1).
#    Disabled engines get no container, port, firewall rule, backup or check.
#    ENABLE_ADMINER (default 0): optional Adminer web UI on 127.0.0.1:$ADMINER_PORT
#    only (never the VPC, no ufw rule); open it through an SSH tunnel.
#
#  ENVIRONMENT OVERRIDES (most common)
#    PRIVATE_IP   bind address (default: eth1 IPv4; required if eth1 is missing)
#    EXPECTED_PRIVATE_IP  abort unless this IP is on the host (wrong-server guard)
#    VPC_CIDR     ufw source range (default 10.0.0.0/8 - set your VPC range)
#    EXTRA_BIND_IPS  more addresses to publish the DB ports on, e.g. the WireGuard
#                 tunnel IP (10.200.0.1). A public address also needs
#                 ALLOW_PUBLIC_BIND=1 and TLS_MODE=require (docs/cross-region.md)
#    PEER_REGIONS regions of the app servers; doctor warns when they differ from
#                 this droplet's region (DO VPCs are per region)
#    PG_USER PG_DB PG_IMAGE PG_BASE_IMAGE PGVECTOR_PKG PGBOUNCER_IMAGE MYSQL_IMAGE
#    MARIADB_IMAGE PG_PORT PGBOUNCER_PORT MYSQL_PORT MARIADB_PORT WEB_ENV CRON_TIME
#    ADMINER_IMAGE ADMINER_PORT
#    DB_DIR       install dir (default /opt/db)
#    BACKUP_DIR   backup root (default $DB_DIR/backups)
#    KEEP         backups kept by `backup` (default 7)
#    FORCE=1      same as --yes (skip the typed confirmation)
#
#  SAFETY
#    reset, restore and uninstall --purge destroy data. They ask you to type
#    RESET / RESTORE / PURGE unless --yes or FORCE=1 is given. reset backs up
#    the old .env to /root/db-env-backup-<timestamp> first. MySQL/MariaDB root
#    passwords are never printed; they live in $DB_DIR/.env.
# =============================================================================
# SC2016: $VARS in single quotes are expanded inside the containers on purpose
# SC2015: "check && ok || problem" lines in doctor are intended (ok/problem never fail)
# SC2329: validators in env-init are called through a variable
# shellcheck disable=SC1091,SC2016,SC2015,SC2329
set -euo pipefail
trap 'echo "!! ERROR: line $LINENO: \"$BASH_COMMAND\" failed" >&2' ERR

TOOL_NAME="Docker DB Server Setup Manager"
VERSION="1.4.0"

# ---- configuration ------------------------------------------------------------
# A config file is KEY=VALUE lines. It only fills in variables the environment
# has not already set, so `sudo PRIVATE_IP=... ./script reset` always wins.
DBM_CONFIG="${DBM_CONFIG:-/etc/docker-db-server-manager.conf}"
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "--config" ]; then j=$((i + 1)); DBM_CONFIG="${!j:-}"; DBM_CONFIG_EXPLICIT=1; fi
done
if [ -f "$DBM_CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
    [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
    k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
    [ -z "${!k+x}" ] && printf -v "$k" '%s' "$v" && export "${k?}"
  done < "$DBM_CONFIG"
elif [ -n "${DBM_CONFIG_EXPLICIT:-}" ]; then
  printf '!! config file not found: %s\n' "$DBM_CONFIG" >&2; exit 1
fi

DB_DIR="${DB_DIR:-/opt/db}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/8}"
BACKUP_DIR="${BACKUP_DIR:-$DB_DIR/backups}"
KEEP="${KEEP:-7}"
FORCE="${FORCE:-0}"
PG_USER="${PG_USER:-app}"
PG_DB="${PG_DB:-app}"
PG_IMAGE="${PG_IMAGE:-vsw/postgres:18-postgis-pgvector}"
PG_BASE_IMAGE="${PG_BASE_IMAGE:-postgis/postgis:18-3.6}"
PGVECTOR_PKG="${PGVECTOR_PKG:-postgresql-18-pgvector}"
PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-200}"
PGBOUNCER_IMAGE="${PGBOUNCER_IMAGE:-edoburu/pgbouncer:v1.26.1-p0}"
PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-500}"
PGBOUNCER_POOL_SIZE="${PGBOUNCER_POOL_SIZE:-20}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:9.7}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:13}"
PG_PORT="${PG_PORT:-5432}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MARIADB_PORT="${MARIADB_PORT:-3307}"
ADMINER_IMAGE="${ADMINER_IMAGE:-adminer:6.1.2-standalone}"
ADMINER_PORT="${ADMINER_PORT:-8081}"
PRIVATE_IFACE="${PRIVATE_IFACE:-eth1}"
CRON_TIME="${CRON_TIME:-15 3 * * *}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/docker-db-server-backup}"
CRON_LOG="${CRON_LOG:-/var/log/docker-db-server-backup.log}"
WEB_ENV="${WEB_ENV:-/home/ploi/<site>-shared/.env}"
ENABLE_POSTGRES="${ENABLE_POSTGRES:-1}"
ENABLE_PGBOUNCER="${ENABLE_PGBOUNCER:-1}"
ENABLE_MYSQL="${ENABLE_MYSQL:-1}"
ENABLE_MARIADB="${ENABLE_MARIADB:-1}"
ENABLE_ADMINER="${ENABLE_ADMINER:-0}"
PG_EXTENSIONS="${PG_EXTENSIONS:-vector postgis pg_trgm pgcrypto uuid-ossp citext pg_stat_statements}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"        # backup refuses to start below this
BACKUP_HOOK="${BACKUP_HOOK:-}"            # optional: run after a good backup, e.g. rclone copy "$1" spaces:bucket/db
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/docker-db-server-backup}"
# ---- hardening (1.4.0) --------------------------------------------------------
# Role split: PG_ADMIN_USER is the only superuser (bootstrap, admin work, backups);
# PG_USER is the app login: no superuser, no CREATEROLE/REPLICATION/BYPASSRLS,
# CREATEDB only when PG_APP_CREATEDB=1 (tenant databases). PgBouncer looks users up
# through PGBOUNCER_AUTH_USER and a SECURITY DEFINER function (never superusers).
PG_ADMIN_USER="${PG_ADMIN_USER:-vsw_admin}"
PG_APP_CREATEDB="${PG_APP_CREATEDB:-1}"
PGBOUNCER_AUTH_USER="${PGBOUNCER_AUTH_USER:-pgbouncer_auth}"
PGBOUNCER_ADMIN_USER="${PGBOUNCER_ADMIN_USER:-pgbouncer_admin}"
PGBOUNCER_POOL_MODE="${PGBOUNCER_POOL_MODE:-session}"
DOCKER_NETWORK="${DOCKER_NETWORK:-vsw_db}"          # compose network with a fixed subnet
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.88.0/24}"    # pg_hba + MySQL root host use it
TLS_MODE="${TLS_MODE:-off}"                         # off | require (self-signed, made on the server)
TLS_DAYS="${TLS_DAYS:-825}"
EXTRA_BIND_IPS="${EXTRA_BIND_IPS:-}"                # more bind addresses (WireGuard IP; public only with the two below)
ALLOW_PUBLIC_BIND="${ALLOW_PUBLIC_BIND:-0}"         # 1 = a public EXTRA_BIND_IPS entry is intended (needs TLS_MODE=require)
PEER_REGIONS="${PEER_REGIONS:-}"                    # app server regions, e.g. "nyc1"; doctor compares with this droplet
METADATA_URL="${METADATA_URL:-http://169.254.169.254/metadata/v1}"   # DO droplet metadata (doctor region check)
PG_LOG_MIN_DURATION="${PG_LOG_MIN_DURATION:-500ms}"
PG_LOG_CONNECTIONS="${PG_LOG_CONNECTIONS:-on}"
PG_IMAGE_LEGACY="${PG_IMAGE_LEGACY:-local/postgres:18-postgis-pgvector}"  # old default tag, retired by upgrade
MARIADB_ED25519="${MARIADB_ED25519:-0}"             # 1 = new MariaDB users use ed25519 (PHP mysqlnd cannot)
MY_APP_HOST="${MY_APP_HOST:-%}"                     # host part of MySQL/MariaDB app users (ports are VPC-only)
BINLOG_DAYS="${BINLOG_DAYS:-7}"                     # MySQL/MariaDB binlog retention on the server
STATE_DIR="${STATE_DIR:-/var/lib/vps-server-workbench/db}"   # status stamps for doctor/monitoring
# ---- environments (approved design; see docs/database-environments.md) --
APP="${APP:-}"                                      # empty = no environment layout
ENVS="${ENVS:-tst dev trn stg prd}"
TENANT_ENVS="${TENANT_ENVS:-$ENVS}"                 # envs whose app role may CREATE tenant DBs
PROTECTED_ENVS="${PROTECTED_ENVS:-stg prd}"
PRD_LOCATION="${PRD_LOCATION:-local}"               # local | droplet | managed (prd not on this host)
ENV_MIGRATOR="${ENV_MIGRATOR:-0}"                   # 1 = separate <app>_<env>_migrator for DDL
ENV_SECRETS_DIR="${ENV_SECRETS_DIR:-/etc/vps-server-workbench/secrets}"
FRESH_BACKUP_MIN="${FRESH_BACKUP_MIN:-15}"          # protected envs: destructive ops need a backup this fresh
TRASH_DAYS="${TRASH_DAYS:-7}"                       # soft-dropped Postgres DBs are purged after this
DROPPED_DUMP_DAYS="${DROPPED_DUMP_DAYS:-30}"        # MySQL/MariaDB: dumps of dropped DBs kept this long
# ---- backups: GFS retention, PITR, off-site, restore tests, alerts --------------
RETENTION="${RETENTION:-}"                          # "daily=14 weekly=8 monthly=12 yearly=2"; empty = KEEP newest
PITR="${PITR:-off}"                                 # off | pgbackrest
PITR_DAYS="${PITR_DAYS:-14}"
PITR_REPO_TYPE="${PITR_REPO_TYPE:-s3}"              # s3 | posix (posix: a local/volume path, tests and NFS)
PITR_REPO_PATH="${PITR_REPO_PATH:-/pgbackrest}"
PITR_FULL_CRON="${PITR_FULL_CRON:-30 2 * * 0}"
PITR_DIFF_CRON="${PITR_DIFF_CRON:-30 2 * * 1-6}"
PGBACKREST_PKG="${PGBACKREST_PKG:-pgbackrest}"
PGBACKREST_MIN_VERSION="${PGBACKREST_MIN_VERSION:-2.60}"
OFFSITE="${OFFSITE:-none}"                          # none | s3 (DigitalOcean Spaces, AWS S3, any S3 API)
OFFSITE_ENDPOINT="${OFFSITE_ENDPOINT:-}"            # e.g. https://ams3.digitaloceanspaces.com
OFFSITE_REGION="${OFFSITE_REGION:-us-east-1}"
OFFSITE_BUCKET="${OFFSITE_BUCKET:-}"
OFFSITE_PREFIX="${OFFSITE_PREFIX:-db/$(hostname 2>/dev/null || echo host)}"
OFFSITE_ENCRYPTION="${OFFSITE_ENCRYPTION:-openssl}" # openssl (AES-256, key file) | age (recipients file)
OFFSITE_KEY_FILE="${OFFSITE_KEY_FILE:-/etc/vps-server-workbench/backup.key}"   # chmod 600
OFFSITE_CREDS_FILE="${OFFSITE_CREDS_FILE:-/etc/vps-server-workbench/offsite.env}" # chmod 600: OFFSITE_ACCESS_KEY / OFFSITE_SECRET_KEY
OFFSITE_TOOL="${OFFSITE_TOOL:-rclone}"              # rclone | aws
OFFSITE_KEEP_DAYS="${OFFSITE_KEEP_DAYS:-400}"
BINLOG_SHIP_CRON="${BINLOG_SHIP_CRON:-*/5 * * * *}"
RESTORE_TEST_CRON="${RESTORE_TEST_CRON:-0 5 * * 0}"
RESTORE_TEST_TIMEOUT="${RESTORE_TEST_TIMEOUT:-3600}"
DOCTOR_CRON="${DOCTOR_CRON:-7 * * * *}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"                  # https URL, JSON POST {event,status,host,message}
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"              # check-in URL (healthchecks.io style: /fail on failure)
ALERT_COMMAND="${ALERT_COMMAND:-}"                  # local hook: <cmd> <event> <ok|fail> <message>
BACKUP_MAX_AGE_H="${BACKUP_MAX_AGE_H:-26}"
RESTORE_TEST_MAX_AGE_D="${RESTORE_TEST_MAX_AGE_D:-8}"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!! WARNING: %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }
on() { [ "$1" = 1 ]; }
engines() { # enabled engine names, in order
  local e=""; on "$ENABLE_POSTGRES" && e="$e postgres"; on "$ENABLE_MYSQL" && e="$e mysql"
  on "$ENABLE_MARIADB" && e="$e mariadb"; echo "${e# }"
}
check_engines() {
  local v; for v in ENABLE_POSTGRES ENABLE_PGBOUNCER ENABLE_MYSQL ENABLE_MARIADB ENABLE_ADMINER; do
    case "${!v}" in 0|1) ;; *) die "$v must be 0 or 1 (got ${!v})" ;; esac
  done
  [ -n "$(engines)" ] || die "every engine is disabled; enable at least one"
  if on "$ENABLE_PGBOUNCER" && ! on "$ENABLE_POSTGRES"; then die "ENABLE_PGBOUNCER=1 needs ENABLE_POSTGRES=1"; fi
}
enabled_ports() {
  on "$ENABLE_POSTGRES" && echo "$PG_PORT"; on "$ENABLE_PGBOUNCER" && echo "$PGBOUNCER_PORT"
  on "$ENABLE_MYSQL" && echo "$MYSQL_PORT"; on "$ENABLE_MARIADB" && echo "$MARIADB_PORT"; return 0
}
banner() { printf '%s\n' "=== $TOOL_NAME :: $1 ===" "    dir=$DB_DIR  ip=$PRIVATE_IP  vpc=$VPC_CIDR"; }

usage() {
cat <<EOF
$TOOL_NAME $VERSION

Usage: $(basename "$0") [--config FILE] <command> [args] [--yes]

Setup and updates
  init [file]                 starter config for this host (private IP, VPC range)
  env-init [flags] [--out F]  environment wizard (prompts; or --app --engines --envs --tenant-dbs
                              --protect --prd-location --pitr --offsite --tls --alert-email --allow env=CIDR
                              --dry-run). Missing value without a terminal: exit 2
  upgrade|apply [--dry-run] [--yes|--non-interactive] [--snapshot|--snapshot-taken|--no-snapshot]
                              preflight -> diff -> confirm -> snapshot -> verified backup -> savepoint
                              -> apply (incl. role split, root@'%' removal) -> verify + doctor -> auto-rollback
  install                     first-time setup (keeps an existing .env and data)
  reset                       DESTRUCTIVE: new passwords, empty databases (type RESET)
  engine enable|disable <postgres|pgbouncer|mysql|mariadb|adminer> [--delete-volume] [--dry-run]
  role-split [--rollback]     the 1.4.0 Postgres role split by hand (upgrade does it for you)

Environments (APP set; docs/database-environments.md)
  env-apply                   create/repair <app>_<env> databases + roles (idempotent)
  env-list | env-sql <env> [engine] | env-creds <env> [engine] [--out F]
  purge-trash [--dry-run]     drop soft-deleted databases older than TRASH_DAYS ($TRASH_DAYS)

Databases and users (privilege model: docs/reference/privileges.md)
  create-db <name> [engine] [--owner U] [--readonly-user] [--tenants] [--extensions a,b] [--out F]
  create-user <user> <db> [engine] [--readonly|--readwrite] [--out F]
  grant <user> <db> [engine] [--readonly|--readwrite]
  rotate-password <user> [engine] [--out F]
  drop-db <name> [engine] [--force-prod] | drop-user <user> [engine] [--force-prod]
  list-dbs [engine|all] | list-users [engine|all]

Backups and recovery (docs/backups-and-recovery.md)
  backup [--cron]             dumps + manifest + checksums, GFS prune (RETENTION), off-site copy (OFFSITE)
  restore <dir> [engine|all]  DESTRUCTIVE (type RESTORE; protected envs: --force-prod + env name)
  restore-test [dir] [--cron] load a backup into throwaway containers (no network), compare the manifest
  offsite backup [dir] | list | verify [name] | fetch <name> [dir]
  pitr setup | backup [full|diff|incr] | status | restore --target 'YYYY-MM-DD HH:MM:SS+00'
  binlog-ship                 copy closed MySQL/MariaDB binlogs (and off-site, encrypted)
  cron-install | cron-remove  backup, doctor --alert, restore-test, PITR, binlog-ship, purge-trash jobs

Checks
  status | verify | doctor [--alert] | logs [service] | env [engine]

Other
  uninstall [--purge]         --purge is DESTRUCTIVE (type PURGE)
  help | --version

Engines: ENABLE_POSTGRES=$ENABLE_POSTGRES ENABLE_PGBOUNCER=$ENABLE_PGBOUNCER ENABLE_MYSQL=$ENABLE_MYSQL ENABLE_MARIADB=$ENABLE_MARIADB ENABLE_ADMINER=$ENABLE_ADMINER
Ports (private IP only): $PG_PORT Postgres, $PGBOUNCER_PORT PgBouncer, $MYSQL_PORT MySQL, $MARIADB_PORT MariaDB
Config: $DBM_CONFIG (see config/db-server.env.example). Docs: docs/tools/db-server-manager.md
Examples:
  sudo ./docker-db-server-manager.sh upgrade --dry-run
  sudo ./docker-db-server-manager.sh env-init --out /etc/docker-db-server-manager.conf
  sudo ./docker-db-server-manager.sh create-db shop --readonly-user --out /root/shop.creds
  sudo WORKBENCH_CONFIRM=prd ./docker-db-server-manager.sh drop-db myapp_prd_t_42 --force-prod
EOF
}

confirm() { # $1 = word to type
  [ "$FORCE" = "1" ] && return 0
  [ -t 0 ] || die "refusing without a terminal; re-run with --yes"
  read -r -p "Type $1 to continue: " answer
  [ "$answer" = "$1" ] || die "aborted"
}

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }
need_stack() {
  [ -f "$DB_DIR/docker-compose.yml" ] || die "no stack in $DB_DIR - run install first"
  cd "$DB_DIR"
  [ -f stack.env ] || write_stack_env   # stacks installed before stack.env existed
}
dc() { (cd "$DB_DIR" && docker compose --env-file .env --env-file stack.env "$@"); }   # works from any cwd
load_env() { set -a; . "$DB_DIR/.env"; set +a; }

detect_ip() {
  if [ -z "${PRIVATE_IP:-}" ]; then
    if [ -f "$DB_DIR/.env" ] && grep -q '^PRIVATE_IP=' "$DB_DIR/.env"; then
      PRIVATE_IP="$(grep '^PRIVATE_IP=' "$DB_DIR/.env" | cut -d= -f2)"
    fi
    if [ -z "${PRIVATE_IP:-}" ]; then
      PRIVATE_IP="$(ip -4 -o addr show "$PRIVATE_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    fi
  fi
}

# Wrong-server guard: with EXPECTED_PRIVATE_IP set, refuse to touch anything
# unless that address is actually configured on this host.
guard_host() {
  [ -n "${EXPECTED_PRIVATE_IP:-}" ] || return 0
  ip -4 -o addr show 2>/dev/null | grep -q "inet ${EXPECTED_PRIVATE_IP//./\\.}/" \
    || die "ABORT: $(hostname) does not have $EXPECTED_PRIVATE_IP - wrong server?"
}

need_ip() { [ -n "${PRIVATE_IP:-}" ] || die "no PRIVATE_IP: $PRIVATE_IFACE has no IPv4; set PRIVATE_IP=<vpc ip>"; }

ensure_docker() {
  log "Docker"
  command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl enable --now docker >/dev/null 2>&1 || warn "could not enable docker service"
  fi
  docker info >/dev/null
  docker compose version
}

new_env() {
  (umask 077; cat > "$DB_DIR/.env" <<EOF
PRIVATE_IP=$PRIVATE_IP
PG_PASSWORD=$(openssl rand -hex 24)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
  )
  chmod 600 "$DB_DIR/.env"
  ensure_env_keys
}

# Secrets added in 1.4.0 are appended to an existing .env (never rotated, never printed).
ENV_KEYS="PG_ADMIN_PASSWORD PGBOUNCER_AUTH_PASSWORD PGBOUNCER_ADMIN_PASSWORD"
ensure_env_keys() { # [file]
  local f="${1:-$DB_DIR/.env}" k added=""
  [ -f "$f" ] || return 0
  for k in $ENV_KEYS; do
    grep -q "^$k=" "$f" || { (umask 077; printf '%s=%s\n' "$k" "$(openssl rand -hex 24)" >> "$f"); added="$added $k"; }
  done
  chmod 600 "$f"
  [ -z "$added" ] || echo "added to $(basename "$f"):$added (generated, not shown)"
}
set_env_key() { # key value [file]: replace or append one line, file stays 600
  local f="${3:-$DB_DIR/.env}" tmp
  tmp="$(mktemp "$f.XXXX")"; chmod 600 "$tmp"
  grep -v "^$1=" "$f" > "$tmp" || true; printf '%s=%s\n' "$1" "$2" >> "$tmp"; mv "$tmp" "$f"
}

# ---- small utilities -----------------------------------------------------------
cidr_mask() { # 24 -> 255.255.255.0
  local b="$1" m=$(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF )); [ "$b" = 0 ] && m=0
  echo "$((m>>24&255)).$((m>>16&255)).$((m>>8&255)).$((m&255))"
}
my_host_of() { # CIDR -> MySQL host part: a.b.c.d/255.255.255.0 (or the IP for /32)
  local ip="${1%/*}" bits="${1#*/}"; [ "$1" = "$ip" ] && bits=32
  if [ "$bits" = 32 ]; then echo "$ip"; else echo "$ip/$(cidr_mask "$bits")"; fi
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; } # word "list"
stamp() { # name [text]: record an event for doctor/monitoring
  mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date +%s)" "${2:-ok}" > "$STATE_DIR/$1" 2>/dev/null || true
}
stamp_age_h() { # name -> hours since stamp, or "" if none
  local t; t="$(awk '{print $1; exit}' "$STATE_DIR/$1" 2>/dev/null)" || true
  [ -n "$t" ] && echo $(( ($(date +%s) - t) / 3600 ))
}

# notify <event> <ok|fail> <message>: monitoring hooks. Never sends secrets; failures only warn.
notify() {
  local ev="$1" st="$2" msg="$3" host; host="$(hostname 2>/dev/null || echo host)"
  msg="$(printf '%s' "$msg" | redact | tr -d '\000-\037"\134' | cut -c1-500)"
  if [ -n "$ALERT_COMMAND" ]; then bash -c "$ALERT_COMMAND \"\$@\"" _ "$ev" "$st" "$msg" || warn "ALERT_COMMAND failed"; fi
  if [ -n "$HEALTHCHECK_URL" ] && [ "$ev" = backup ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECK_URL$([ "$st" = ok ] || echo /fail)" || warn "healthcheck ping failed"
  fi
  [ "$st" = ok ] && [ "${ALERT_ON_OK:-0}" != 1 ] && return 0
  if [ -n "$ALERT_WEBHOOK" ]; then
    curl -fsS -m 10 --retry 2 -o /dev/null -H 'Content-Type: application/json' \
      -d "{\"event\":\"$ev\",\"status\":\"$st\",\"host\":\"$host\",\"message\":\"$msg\"}" "$ALERT_WEBHOOK" || warn "alert webhook failed"
  fi
  if [ -n "$ALERT_EMAIL" ]; then
    if command -v mail >/dev/null 2>&1; then printf '%s\n' "$msg" | mail -s "[$host] db $ev: $st" "$ALERT_EMAIL" || warn "alert mail failed"
    else warn "ALERT_EMAIL set but no 'mail' command (apt install mailutils)"; fi
  fi
}

write_stack_env() { # non-secret compose settings; safe to rewrite at any time
  (cd "$DB_DIR" && cat > stack.env <<EOF
# non-secret settings, rewritten by $TOOL_NAME on every install/reset
PG_USER=$PG_USER
PG_ADMIN_USER=$PG_ADMIN_USER
PGBOUNCER_AUTH_USER=$PGBOUNCER_AUTH_USER
PGBOUNCER_ADMIN_USER=$PGBOUNCER_ADMIN_USER
PGBOUNCER_POOL_MODE=$PGBOUNCER_POOL_MODE
DOCKER_NETWORK=$DOCKER_NETWORK
DOCKER_SUBNET=$DOCKER_SUBNET
PG_EXTRA_PKGS=$(pitr_on && echo "$PGBACKREST_PKG")
PG_DB=$PG_DB
PG_IMAGE=$PG_IMAGE
PG_BASE_IMAGE=$PG_BASE_IMAGE
PGVECTOR_PKG=$PGVECTOR_PKG
PG_MAX_CONNECTIONS=$PG_MAX_CONNECTIONS
PGBOUNCER_IMAGE=$PGBOUNCER_IMAGE
PGBOUNCER_MAX_CLIENT_CONN=$PGBOUNCER_MAX_CLIENT_CONN
PGBOUNCER_POOL_SIZE=$PGBOUNCER_POOL_SIZE
MYSQL_IMAGE=$MYSQL_IMAGE
MARIADB_IMAGE=$MARIADB_IMAGE
PG_PORT=$PG_PORT
PGBOUNCER_PORT=$PGBOUNCER_PORT
MYSQL_PORT=$MYSQL_PORT
MARIADB_PORT=$MARIADB_PORT
ADMINER_IMAGE=$ADMINER_IMAGE
ADMINER_PORT=$ADMINER_PORT
EOF
  )
}

pitr_on() { [ "$PITR" = pgbackrest ] && on "$ENABLE_POSTGRES"; }
tls_on() { [ "$TLS_MODE" = require ]; }

# pg_hba: loopback + the compose network (PgBouncer, Adminer) + the VPC; never "all".
# With APP set, each environment's roles may only reach their own databases, and only
# from ALLOW_<env> (default ALLOW_default, else VPC_CIDR). Through PgBouncer the source
# is the PgBouncer container, so per-env IP limits apply to direct (5432) logins.
write_pg_hba() { # file
  local h="host" e envdb roles a allow
  tls_on && h="hostssl"
  {
    echo "# generated by $TOOL_NAME $VERSION - edit the config, not this file"
    echo "# TYPE   DATABASE  USER  ADDRESS  METHOD"
    echo "local    all       all            trust"
    echo "host     all       all   127.0.0.1/32  scram-sha-256"
    echo "host     all       all   ::1/128       scram-sha-256"
    echo "host     all       $PGBOUNCER_ADMIN_USER  all  reject"
    echo "host     all       $PG_ADMIN_USER  $DOCKER_SUBNET  scram-sha-256"
    echo "$h  all       $PG_ADMIN_USER  $VPC_CIDR  scram-sha-256"
    if [ -n "$APP" ]; then
      for e in $(local_envs); do
        envdb="/^${APP}_${e}(_t_[a-z0-9_]+)?\$"
        roles="$(env_role "$e" app),$(env_role "$e" ro)"; [ "$ENV_MIGRATOR" = 1 ] && roles="$roles,$(env_role "$e" migrator)"
        allow="$(env_allow "$e")"
        echo "# env $e"
        echo "host     $envdb  $roles  $DOCKER_SUBNET  scram-sha-256"
        for a in ${allow//,/ }; do echo "$h  $envdb  $roles  $a  scram-sha-256"; done
        echo "host     all  $roles  all  reject"
        echo "host     $envdb  all  all  reject"
      done
    fi
    echo "host     all       all   $DOCKER_SUBNET  scram-sha-256"
    echo "$h  all       all   $VPC_CIDR  scram-sha-256"
  } > "$1"
}

add_binds() { # copy each '${PRIVATE_IP}:port' mapping to every EXTRA_BIND_IPS address
  local line ip extra
  while IFS= read -r line; do
    if [[ "$line" =~ ^(.*ports:\ \[)\"\$\{PRIVATE_IP\}:(\$\{[A-Z_]+\}:[0-9]+)\"\]$ ]]; then
      extra=""; for ip in $(extra_binds); do extra="$extra, \"$ip:${BASH_REMATCH[2]}\""; done
      printf '%s"${PRIVATE_IP}:%s"%s]\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$extra"
    else printf '%s\n' "$line"; fi
  done
}
write_files() {
  log "Writing files in $DB_DIR"
  cd "$DB_DIR"
  mkdir -p postgres/init postgres/conf
  {
    cat <<'EOF'
# postgis/postgis is amd64-only (fine for DO droplets)
ARG PG_BASE_IMAGE
FROM ${PG_BASE_IMAGE}
ARG PGVECTOR_PKG
ARG EXTRA_PKGS=""
# apt packages are GPG-signed; ca-certificates first so the pgdg repo can switch to https
RUN apt-get -o Acquire::Retries=5 update \
 && apt-get -o Acquire::Retries=5 install -y --no-install-recommends ca-certificates \
 && for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do [ -f "$f" ] && sed -i 's|http://apt.postgresql.org|https://apt.postgresql.org|g' "$f"; done; \
 apt-get -o Acquire::Retries=5 update \
 && apt-get -o Acquire::Retries=5 install -y --no-install-recommends ${PGVECTOR_PKG} ${EXTRA_PKGS} \
 && rm -rf /var/lib/apt/lists/*
EOF
  } > postgres/Dockerfile

  local ext sql=""
  for ext in $PG_EXTENSIONS; do sql="${sql}CREATE EXTENSION IF NOT EXISTS \"$ext\";
"; done
  cat > postgres/init/10-extensions.sql <<EOF
-- runs once, on an empty data dir. template1 => every database created later gets these.
-- upgrade re-applies the same list to template1 and $PG_DB on existing servers.
\\set ON_ERROR_STOP on
\\c template1
${sql}\\c $PG_DB
${sql}
EOF
  write_pg_hba postgres/conf/pg_hba.conf
  # entrypoint wrapper: copies the TLS key with the owner/mode Postgres insists on
  cat > postgres/conf/entry.sh <<'EOF'
#!/bin/sh
# generated: prepare TLS files for the postgres user, then hand over to the image entrypoint
set -e
if [ -f /etc/postgresql/vsw/tls/server.key ]; then
  install -d -o postgres -g postgres -m 700 /run/vsw-tls
  install -o postgres -g postgres -m 600 /etc/postgresql/vsw/tls/server.key /run/vsw-tls/server.key
  install -o postgres -g postgres -m 644 /etc/postgresql/vsw/tls/server.crt /run/vsw-tls/server.crt
fi
if [ -f /etc/postgresql/vsw/pgbackrest.conf ]; then
  install -d -o postgres -g postgres -m 750 /tmp/pgbackrest /var/log/pgbackrest
  if grep -q '^repo1-type=posix' /etc/postgresql/vsw/pgbackrest.conf; then
    repo="$(sed -n 's/^repo1-path=//p' /etc/postgresql/vsw/pgbackrest.conf)"
    [ -n "$repo" ] && install -d -o postgres -g postgres -m 750 "$repo" && chown -R postgres:postgres "$repo"
  fi
fi
exec docker-entrypoint.sh "$@"
EOF
  chmod 755 postgres/conf/entry.sh
  if pitr_on; then write_pgbackrest_conf postgres/conf/pgbackrest.conf; else rm -f postgres/conf/pgbackrest.conf; fi
  if tls_on; then ensure_tls; fi

  write_stack_env

  local pgcmd mycmd macmd
  pgcmd="\"postgres\", \"-c\", \"shared_preload_libraries=pg_stat_statements\", \"-c\", \"max_connections=\${PG_MAX_CONNECTIONS}\", \"-c\", \"hba_file=/etc/postgresql/vsw/pg_hba.conf\", \"-c\", \"log_connections=$PG_LOG_CONNECTIONS\", \"-c\", \"log_disconnections=on\", \"-c\", \"log_min_duration_statement=$PG_LOG_MIN_DURATION\""
  tls_on && pgcmd="$pgcmd, \"-c\", \"ssl=on\", \"-c\", \"ssl_cert_file=/run/vsw-tls/server.crt\", \"-c\", \"ssl_key_file=/run/vsw-tls/server.key\", \"-c\", \"ssl_min_protocol_version=TLSv1.2\""
  pitr_on && pgcmd="$pgcmd, \"-c\", \"archive_mode=on\", \"-c\", \"archive_command=pgbackrest --config=/etc/postgresql/vsw/pgbackrest.conf --stanza=main archive-push %p\", \"-c\", \"archive_timeout=60\""
  mycmd="\"--local-infile=0\", \"--binlog-expire-logs-seconds=$((BINLOG_DAYS * 86400))\""
  tls_on && mycmd="$mycmd, \"--require-secure-transport=ON\""
  macmd="\"--local-infile=0\", \"--secure-file-priv=/var/lib/mysql-files\", \"--log-bin=mariadb-bin\", \"--server-id=1\", \"--binlog-expire-logs-seconds=$((BINLOG_DAYS * 86400))\""
  tls_on && macmd="$macmd, \"--require-secure-transport=ON\""
  [ "$MARIADB_ED25519" = 1 ] && macmd="$macmd, \"--plugin-load-add=auth_ed25519\""

{
  echo "# generated by $TOOL_NAME $VERSION - edit the config, not this file"
  echo "services:"
  if on "$ENABLE_POSTGRES"; then cat <<'EOF'
  postgres:
    build:
      context: ./postgres
      args:
        PG_BASE_IMAGE: ${PG_BASE_IMAGE}
        PGVECTOR_PKG: ${PGVECTOR_PKG}
        EXTRA_PKGS: ${PG_EXTRA_PKGS}
    image: ${PG_IMAGE}
    restart: unless-stopped
    entrypoint: ["/etc/postgresql/vsw/entry.sh"]
EOF
    echo "    command: [$pgcmd]"
    cat <<'EOF'
    environment:
      # bootstrap superuser = the admin role; the app login (PG_USER) is created by the manager
      POSTGRES_USER: ${PG_ADMIN_USER}
      POSTGRES_PASSWORD: ${PG_ADMIN_PASSWORD}
      POSTGRES_DB: ${PG_DB}
    ports: ["${PRIVATE_IP}:${PG_PORT}:5432"]
    volumes:
      # postgres 18 images keep data in /var/lib/postgresql/18/docker; mount the parent
      - pg_data:/var/lib/postgresql
      - ./postgres/init:/docker-entrypoint-initdb.d:ro
      - ./postgres/conf:/etc/postgresql/vsw:ro
EOF
    if pitr_on; then
      [ "$PITR_REPO_TYPE" = posix ] && echo "      - pg_pitr:$PITR_REPO_PATH"
      echo "    env_file: [./postgres/pitr.env]"
    fi
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U ${PG_ADMIN_USER} -d ${PG_DB}"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 30s

EOF
  fi
  if on "$ENABLE_PGBOUNCER"; then cat <<'EOF'
  pgbouncer:
    image: ${PGBOUNCER_IMAGE}
    restart: unless-stopped
    depends_on: { postgres: { condition: service_healthy } }
    environment:
      # only the auth user goes into userlist.txt; every other login is looked up with
      # auth_query through a SECURITY DEFINER function that never returns superusers
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_USER: ${PGBOUNCER_AUTH_USER}
      DB_PASSWORD: ${PGBOUNCER_AUTH_PASSWORD}
      AUTH_TYPE: scram-sha-256
      AUTH_USER: ${PGBOUNCER_AUTH_USER}
      AUTH_QUERY: "SELECT usename, passwd FROM pgbouncer.get_auth($$1)"
      AUTH_DBNAME: postgres
      POOL_MODE: ${PGBOUNCER_POOL_MODE}
      MAX_CLIENT_CONN: "${PGBOUNCER_MAX_CLIENT_CONN}"
      DEFAULT_POOL_SIZE: "${PGBOUNCER_POOL_SIZE}"
      ADMIN_USERS: ${PGBOUNCER_ADMIN_USER}
      STATS_USERS: ${PGBOUNCER_ADMIN_USER}
      LISTEN_PORT: "5432"
EOF
    if tls_on; then cat <<'EOF'
      CLIENT_TLS_SSLMODE: require
      CLIENT_TLS_KEY_FILE: /etc/pgbouncer/tls/server.key
      CLIENT_TLS_CERT_FILE: /etc/pgbouncer/tls/server.crt
    volumes: ["./pgbouncer/tls:/etc/pgbouncer/tls:ro"]
EOF
    fi
    cat <<'EOF'
    ports: ["${PRIVATE_IP}:${PGBOUNCER_PORT}:5432"]
    healthcheck:
      # "pgbouncer" admin DB is virtual: checks the pooler without hitting postgres
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432 -U ${PGBOUNCER_ADMIN_USER} -d pgbouncer"]
      interval: 5s
      timeout: 5s
      retries: 30

EOF
  fi
  if on "$ENABLE_MYSQL"; then cat <<'EOF'
  mysql:
    image: ${MYSQL_IMAGE}
    restart: unless-stopped
EOF
    echo "    command: [$mycmd]"
    cat <<'EOF'
    environment:
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASSWORD}"
      MYSQL_ROOT_HOST: localhost       # new installs: no root@'%' (upgrade removes it on old ones)
    ports: ["${PRIVATE_IP}:${MYSQL_PORT}:3306"]
    volumes: [mysql_data:/var/lib/mysql]
    healthcheck:
      test: ["CMD-SHELL", "MYSQL_PWD=\"$$MYSQL_ROOT_PASSWORD\" mysqladmin ping -uroot --silent"]
      interval: 5s
      timeout: 5s
      retries: 60
      start_period: 30s

EOF
  fi
  if on "$ENABLE_MARIADB"; then cat <<'EOF'
  mariadb:
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
EOF
    echo "    command: [$macmd]"
    cat <<'EOF'
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_ROOT_HOST: localhost
      MARIADB_AUTO_UPGRADE: "1"
    ports: ["${PRIVATE_IP}:${MARIADB_PORT}:3306"]
    volumes: [mariadb_data:/var/lib/mysql]
    tmpfs: [/var/lib/mysql-files]     # secure_file_priv target: exists, empty, not persistent
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 60
      start_period: 30s

EOF
  fi
  if on "$ENABLE_ADMINER"; then cat <<'EOF'
  adminer:
    # optional web UI. Loopback only: never the private IP, never public.
    # Open with: ssh -N -L 8081:127.0.0.1:${ADMINER_PORT} <user>@<db-public-ip>
    # Login = a real database user + password (Adminer refuses empty passwords).
    image: ${ADMINER_IMAGE}
    restart: unless-stopped
    environment:
      ADMINER_DEFAULT_SERVER: postgres
    ports: ["127.0.0.1:${ADMINER_PORT}:8080"]
    read_only: true
    tmpfs: [/tmp]
    security_opt: ["no-new-privileges:true"]

EOF
  fi
  cat <<'EOF'
networks:
  default:
    name: ${DOCKER_NETWORK}
    # IPv4 only: pg_hba and the MySQL root host list are written for DOCKER_SUBNET
    enable_ipv6: false
    ipam: { config: [ { subnet: "${DOCKER_SUBNET}" } ] }
EOF
  local vols=""
  on "$ENABLE_POSTGRES" && vols="$vols pg_data: {},"
  pitr_on && [ "$PITR_REPO_TYPE" = posix ] && vols="$vols pg_pitr: {},"
  on "$ENABLE_MYSQL" && vols="$vols mysql_data: {},"
  on "$ENABLE_MARIADB" && vols="$vols mariadb_data: {},"
  echo "volumes: {${vols%,} }"
} | add_binds > docker-compose.yml
  if pitr_on; then pitr_env_file > postgres/pitr.env; chmod 600 postgres/pitr.env; else rm -f postgres/pitr.env; fi
  dc config -q
}

# self-signed CA + server certificate, made on the server (keys never leave it).
# Clients use sslmode=require; for verify-full copy $DB_DIR/tls/ca.crt to the web hosts.
ensure_tls() {
  local d="$DB_DIR/tls"
  (umask 077; mkdir -p "$d")
  local want_ip have_sans; have_sans="$(openssl x509 -noout -ext subjectAltName -in "$d/server.crt" 2>/dev/null || true)"
  for want_ip in "$PRIVATE_IP" $(extra_binds); do
    [ -z "$have_sans" ] || grep -q "IP Address:$want_ip\$\|IP Address:$want_ip," <<<"$have_sans" || { echo "TLS: certificate lacks $want_ip - reissuing"; rm -f "$d/server.crt"; break; }
  done
  if [ ! -f "$d/server.crt" ] || ! openssl x509 -checkend $((30 * 86400)) -noout -in "$d/server.crt" >/dev/null 2>&1; then
    echo "TLS: generating a CA and server certificate in $d ($TLS_DAYS days)"
    [ -f "$d/ca.key" ] || openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=vsw-db-ca $(hostname)" \
      -keyout "$d/ca.key" -out "$d/ca.crt" >/dev/null 2>&1
    openssl req -newkey rsa:3072 -nodes -subj "/CN=$PRIVATE_IP" -keyout "$d/server.key" -out "$d/server.csr" >/dev/null 2>&1
    local san="IP:$PRIVATE_IP" x; for x in $(extra_binds); do san="$san,IP:$x"; done
    printf 'subjectAltName=%s,DNS:postgres,DNS:pgbouncer,DNS:localhost\n' "$san" > "$d/san.ext"
    openssl x509 -req -in "$d/server.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial -days "$TLS_DAYS" \
      -extfile "$d/san.ext" -out "$d/server.crt" >/dev/null 2>&1
    rm -f "$d/server.csr" "$d/san.ext"; chmod 600 "$d"/*.key
  fi
  mkdir -p postgres/conf/tls pgbouncer/tls
  install -m 600 "$d/server.key" postgres/conf/tls/server.key; install -m 644 "$d/server.crt" postgres/conf/tls/server.crt
  # pgbouncer runs as uid 70 and reads the key directly
  install -m 600 "$d/server.key" pgbouncer/tls/server.key; install -m 644 "$d/server.crt" pgbouncer/tls/server.crt
  chown 70:70 pgbouncer/tls/server.key 2>/dev/null || chmod 644 pgbouncer/tls/server.key
}

# ---- PITR (pgBackRest) config ----------------------------------------------------
# Secrets (S3 keys, repository cipher passphrase) come from OFFSITE_CREDS_FILE and go to
# postgres/pitr.env (chmod 600) as PGBACKREST_* variables; pgbackrest.conf has none.
write_pgbackrest_conf() { # file
  {
    echo "# generated by $TOOL_NAME $VERSION - no secrets here (see postgres/pitr.env)"
    echo "[global]"
    echo "repo1-type=$PITR_REPO_TYPE"
    echo "repo1-path=$PITR_REPO_PATH"
    if [ "$PITR_REPO_TYPE" = s3 ]; then
      echo "repo1-s3-bucket=$OFFSITE_BUCKET"
      echo "repo1-s3-endpoint=${OFFSITE_ENDPOINT#https://}"
      echo "repo1-s3-region=$OFFSITE_REGION"
    fi
    echo "repo1-retention-full-type=time"
    echo "repo1-retention-full=$PITR_DAYS"
    echo "repo1-cipher-type=aes-256-cbc"
    echo "compress-type=zst"
    echo "start-fast=y"
    echo "process-max=2"
    echo "archive-async=n"
    echo "log-level-console=info"
    echo "log-level-file=info"
    echo "log-path=/var/log/pgbackrest"
    echo "lock-path=/tmp/pgbackrest"
    echo "[main]"
    echo "pg1-path=/var/lib/postgresql/18/docker"
    echo "pg1-socket-path=/var/run/postgresql"
    echo "pg1-user=$PG_ADMIN_USER"
  } > "$1"
}
offsite_creds() { # loads OFFSITE_ACCESS_KEY / OFFSITE_SECRET_KEY from the 600 file (never printed)
  [ -f "$OFFSITE_CREDS_FILE" ] || return 1
  local m; m="$(stat -c %a "$OFFSITE_CREDS_FILE" 2>/dev/null || stat -f %Lp "$OFFSITE_CREDS_FILE")"
  [ "$m" = 600 ] || die "$OFFSITE_CREDS_FILE must be chmod 600 (is $m)"
  local k v line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^(OFFSITE_ACCESS_KEY|OFFSITE_SECRET_KEY|PITR_CIPHER_PASS)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; v="${v%\"}"; v="${v#\"}"; printf -v "$k" '%s' "$v"
  done < "$OFFSITE_CREDS_FILE"
  return 0
}
pitr_env_file() { # stdout: PGBACKREST_* secrets for the postgres container
  local OFFSITE_ACCESS_KEY="" OFFSITE_SECRET_KEY="" PITR_CIPHER_PASS=""
  offsite_creds || [ "$PITR_REPO_TYPE" = posix ] || die "PITR=pgbackrest with s3 needs $OFFSITE_CREDS_FILE (OFFSITE_ACCESS_KEY, OFFSITE_SECRET_KEY, PITR_CIPHER_PASS)"
  [ -n "$PITR_CIPHER_PASS" ] || PITR_CIPHER_PASS="$(pitr_cipher_from_env)"
  echo "PGBACKREST_REPO1_CIPHER_PASS=$PITR_CIPHER_PASS"
  if [ "$PITR_REPO_TYPE" = s3 ]; then
    echo "PGBACKREST_REPO1_S3_KEY=$OFFSITE_ACCESS_KEY"
    echo "PGBACKREST_REPO1_S3_KEY_SECRET=$OFFSITE_SECRET_KEY"
  fi
}
pitr_cipher_from_env() { # a cipher pass kept in .env when the creds file has none (posix repos)
  local f="$DB_DIR/.env"; [ -f "$f" ] || f="${REAL_DB_DIR:-$DB_DIR}/.env"
  grep -q '^PITR_CIPHER_PASS=' "$f" 2>/dev/null || set_env_key PITR_CIPHER_PASS "$(openssl rand -hex 32)" "$f"
  sed -n 's/^PITR_CIPHER_PASS=//p' "$f"
}

# ---- converge: idempotent security settings inside the running engines -----------
# Runs after the containers are up (install, upgrade, harden). Every statement is safe
# to repeat. Legacy servers (app login = bootstrap superuser) get the role split.
PG_SU=""
pg_su() { # the superuser to connect as over the container's local socket (trust)
  if [ -z "$PG_SU" ]; then
    if dc exec -T postgres psql -X -q -U "$PG_ADMIN_USER" -d postgres -tAc 'select 1' </dev/null >/dev/null 2>&1; then PG_SU="$PG_ADMIN_USER"
    else PG_SU="$PG_USER"; fi
  fi
  echo "$PG_SU"
}
pg_q() { # [db] ; SQL on stdin
  dc exec -T postgres psql -q -X -v ON_ERROR_STOP=1 -U "$(pg_su)" -d "${1:-postgres}" -tA -f -
}
pg_q_as() { # role db ; SQL on stdin (local socket, trust)
  dc exec -T postgres psql -q -X -v ON_ERROR_STOP=1 -U "$1" -d "$2" -tA -f -
}
pg_val() { printf '%s\n' "$2" | pg_q "$1"; } # db sql -> value
sql_lit() { printf "'%s'" "${1//\'/\'\'}"; }
pg_legacy() { # app login is still a superuser and no admin role exists
  [ "$(pg_val postgres "select count(*) from pg_roles where rolname='$PG_ADMIN_USER'")" = 0 ] \
    && [ "$(pg_val postgres "select count(*) from pg_roles where rolname='$PG_USER' and rolsuper")" = 1 ]
}
# copy objects + default privileges owned by role $1 to role $2 in database $3
# (extension members and table-owned sequences follow their parent; system schemas skipped)
pg_move_ownership_sql() {
  cat <<SQL
DO \$vsw\$ DECLARE r record; src oid := (select oid from pg_roles where rolname = $(sql_lit "$1")); BEGIN
  FOR r IN SELECT n.nspname FROM pg_namespace n WHERE n.nspowner = src AND n.nspname NOT IN ('pg_catalog','information_schema','pgbouncer') AND n.nspname NOT LIKE 'pg\_%'
  LOOP EXECUTE format('ALTER SCHEMA %I OWNER TO %I', r.nspname, $(sql_lit "$2")); END LOOP;
  FOR r IN SELECT c.oid::regclass AS o, CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END AS k
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relowner = src AND c.relkind IN ('r','p','v','m','S','f')
      AND n.nspname NOT IN ('pg_catalog','information_schema','pgbouncer') AND n.nspname NOT LIKE 'pg\_%'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('e','a','i'))
  LOOP EXECUTE format('ALTER %s %s OWNER TO %I', r.k, r.o, $(sql_lit "$2")); END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS o FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proowner = src AND n.nspname NOT IN ('pg_catalog','information_schema','pgbouncer') AND n.nspname NOT LIKE 'pg\_%'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  LOOP EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.o, $(sql_lit "$2")); END LOOP;
  FOR r IN SELECT t.oid::regtype AS o FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typowner = src AND t.typtype IN ('e','d','r') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg\_%'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
  LOOP EXECUTE format('ALTER TYPE %s OWNER TO %I', r.o, $(sql_lit "$2")); END LOOP;
  FOR r IN SELECT d.defaclnamespace AS ns, d.defaclobjtype AS t, a.grantee, a.privilege_type AS p
    FROM pg_default_acl d, aclexplode(d.defaclacl) a WHERE d.defaclrole = src AND a.grantee <> src
  LOOP
    CONTINUE WHEN r.t = 'n' AND r.ns <> 0;
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I %s GRANT %s ON %s TO %s', $(sql_lit "$2"),
      CASE WHEN r.ns = 0 THEN '' ELSE 'IN SCHEMA ' || quote_ident((select nspname from pg_namespace where oid = r.ns)) END,
      r.p, CASE r.t WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES' WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' ELSE 'SCHEMAS' END,
      CASE WHEN r.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(r.grantee)) END);
  END LOOP;
END \$vsw\$;
SQL
}
app_role_attrs() { printf 'NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS %s' "$([ "$PG_APP_CREATEDB" = 1 ] && echo CREATEDB || echo NOCREATEDB)"; }

# Explicit, reversible migration for servers installed before 1.4.0, where PG_USER is
# the bootstrap superuser. The bootstrap role keeps its oid and becomes PG_ADMIN_USER;
# a new, non-superuser PG_USER (same password) takes over the app's objects.
# Sessions of PG_USER are ended first (a renamed live session would stay superuser).
pg_role_split() {
  pg_legacy || { echo "role split: not needed (app login '$PG_USER' is not a superuser)"; return 0; }
  log "Postgres role split: $PG_USER (superuser) -> $PG_ADMIN_USER (admin) + $PG_USER (app, no superuser)"
  load_env
  local dbs d
  dbs="$(pg_val postgres "select string_agg(datname, ' ') from pg_database d join pg_roles r on r.oid = d.datdba where r.rolname = '$PG_USER' and datname not in ('postgres','template0','template1')")"
  if on "$ENABLE_PGBOUNCER"; then dc stop pgbouncer >/dev/null 2>&1 || true; fi
  printf 'CREATE ROLE vsw_migrate SUPERUSER LOGIN;\n' | pg_q_as "$PG_USER" postgres
  { printf "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = %s AND pid <> pg_backend_pid();\n" "$(sql_lit "$PG_USER")"
    printf 'ALTER ROLE "%s" RENAME TO "%s";\n' "$PG_USER" "$PG_ADMIN_USER"
    printf "ALTER ROLE \"%s\" PASSWORD %s;\n" "$PG_ADMIN_USER" "$(sql_lit "$PG_ADMIN_PASSWORD")"
    printf "CREATE ROLE \"%s\" LOGIN %s PASSWORD %s;\n" "$PG_USER" "$(app_role_attrs)" "$(sql_lit "$PG_PASSWORD")"
  } | pg_q_as vsw_migrate postgres >/dev/null
  PG_SU="$PG_ADMIN_USER"
  printf 'DROP ROLE vsw_migrate;\n' | pg_q postgres
  for d in $dbs; do
    pg_move_ownership_sql "$PG_ADMIN_USER" "$PG_USER" | pg_q "$d"
    # the main DB stays admin-owned (only an admin may drop it); tenant DBs the app made stay the app's
    [ "$d" = "$PG_DB" ] || printf 'ALTER DATABASE "%s" OWNER TO "%s";\n' "$d" "$PG_USER" | pg_q
    echo "  $d: objects of the old login now belong to $PG_USER"
  done
  stamp role-split "$dbs"
  echo "role split done. Rollback: role-split --rollback (also automatic if this upgrade fails)"
}
pg_role_split_rollback() {
  [ "$(pg_val postgres "select count(*) from pg_roles where rolname='$PG_ADMIN_USER' and oid = 10")" = 1 ] \
    || die "nothing to roll back: $PG_ADMIN_USER is not the bootstrap role (fresh 1.4 install, or already rolled back)"
  log "Postgres role split ROLLBACK: $PG_ADMIN_USER -> $PG_USER (superuser again)"
  load_env
  local d
  if on "$ENABLE_PGBOUNCER"; then dc stop pgbouncer >/dev/null 2>&1 || true; fi
  for d in $(pg_val postgres "select string_agg(datname, ' ') from pg_database where datallowconn"); do
    printf 'REASSIGN OWNED BY "%s" TO "%s";\nDROP OWNED BY "%s";\n' "$PG_USER" "$PG_ADMIN_USER" "$PG_USER" | pg_q "$d"
  done
  printf 'CREATE ROLE vsw_migrate SUPERUSER LOGIN;\n' | pg_q postgres
  { printf "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename IN (%s, %s) AND pid <> pg_backend_pid();\n" "$(sql_lit "$PG_USER")" "$(sql_lit "$PG_ADMIN_USER")"
    printf 'DROP ROLE "%s";\n' "$PG_USER"
    printf 'ALTER ROLE "%s" RENAME TO "%s";\n' "$PG_ADMIN_USER" "$PG_USER"
    printf "ALTER ROLE \"%s\" PASSWORD %s;\n" "$PG_USER" "$(sql_lit "$PG_PASSWORD")"
  } | pg_q_as vsw_migrate postgres >/dev/null
  printf 'DROP ROLE vsw_migrate;\n' | pg_q_as "$PG_USER" postgres
  PG_SU="$PG_USER"
  echo "role split rolled back: $PG_USER is the superuser again (as before 1.4.0)"
}
cmd_role_split() { # [--rollback]
  need_root; need_stack; load_env
  if [ "${1:-}" = --rollback ]; then
    echo "This makes $PG_USER a SUPERUSER again (the pre-1.4.0 layout)."; confirm ROLLBACK; pg_role_split_rollback
  else
    pg_legacy || { echo "role split: not needed"; return 0; }
    echo "Ends $PG_USER's open sessions for a few seconds, then moves its objects to a new non-superuser $PG_USER."
    confirm SPLIT; cmd_backup; pg_role_split; pg_converge
  fi
  if on "$ENABLE_PGBOUNCER"; then dc up -d --wait pgbouncer; fi
}

pg_converge() {
  on "$ENABLE_POSTGRES" || return 0
  log "Postgres hardening (idempotent)"
  load_env
  pg_legacy && pg_role_split
  local x
  # app login: never superuser; CREATEDB only for tenant databases
  if [ "$(pg_val postgres "select count(*) from pg_roles where rolname='$PG_USER'")" = 0 ]; then
    printf "CREATE ROLE \"%s\" LOGIN %s PASSWORD %s;\n" "$PG_USER" "$(app_role_attrs)" "$(sql_lit "$PG_PASSWORD")" | pg_q
  else
    printf 'ALTER ROLE "%s" LOGIN %s;\n' "$PG_USER" "$(app_role_attrs)" | pg_q
  fi
  { printf 'ALTER DATABASE "%s" OWNER TO "%s";\n' "$PG_DB" "$(pg_su)"
    printf 'REVOKE ALL ON DATABASE "%s" FROM PUBLIC;\n' "$PG_DB"
    printf 'GRANT CONNECT, TEMPORARY ON DATABASE "%s" TO "%s";\n' "$PG_DB" "$PG_USER"; } | pg_q
  { printf 'ALTER SCHEMA public OWNER TO "%s";\n' "$PG_USER"
    printf 'REVOKE CREATE ON SCHEMA public FROM PUBLIC;\n'; } | pg_q "$PG_DB"
  # extensions (citext etc.) on servers whose init script ran with an older list
  for x in $PG_EXTENSIONS; do
    for d in template1 "$PG_DB"; do
      printf 'CREATE EXTENSION IF NOT EXISTS "%s";\n' "$x" | pg_q "$d" >/dev/null 2>&1 || warn "extension $x not available in $d"
    done
  done
  # PgBouncer lookup: dedicated login + SECURITY DEFINER function; superusers are never returned
  { printf "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %s) THEN CREATE ROLE \"%s\" LOGIN; END IF; END \$\$;\n" "$(sql_lit "$PGBOUNCER_AUTH_USER")" "$PGBOUNCER_AUTH_USER"
    printf "ALTER ROLE \"%s\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %s;\n" "$PGBOUNCER_AUTH_USER" "$(sql_lit "$PGBOUNCER_AUTH_PASSWORD")"
    printf "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %s) THEN CREATE ROLE \"%s\" LOGIN; END IF; END \$\$;\n" "$(sql_lit "$PGBOUNCER_ADMIN_USER")" "$PGBOUNCER_ADMIN_USER"
    printf "ALTER ROLE \"%s\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %s;\n" "$PGBOUNCER_ADMIN_USER" "$(sql_lit "$PGBOUNCER_ADMIN_PASSWORD")"
    cat <<SQL
CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION "$(pg_su)";
REVOKE ALL ON SCHEMA pgbouncer FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO "$PGBOUNCER_AUTH_USER";
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text) RETURNS TABLE (usename name, passwd text)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS
\$f\$ SELECT rolname, CASE WHEN rolvaliduntil IS NULL OR rolvaliduntil > now() THEN rolpassword END
     FROM pg_authid WHERE rolname = p_usename AND rolcanlogin AND NOT rolsuper \$f\$;
REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO "$PGBOUNCER_AUTH_USER";
SQL
  } | pg_q postgres
  echo "postgres: $PG_ADMIN_USER = only superuser, $PG_USER = app ($(app_role_attrs)), pgbouncer auth via $PGBOUNCER_AUTH_USER"
  [ -z "$APP" ] || env_apply_engine postgres
}

# MySQL/MariaDB: no root@'%'. root stays on localhost (socket), 127.0.0.1 and the compose
# network (Adminer). Runs over the socket so it works whatever root hosts exist.
my_q() { # engine ; SQL on stdin (socket, root)
  local cli=mysql rv=MYSQL_ROOT_PASSWORD
  [ "$1" = mariadb ] && cli=mariadb rv=MARIADB_ROOT_PASSWORD
  dc exec -T "$1" sh -c "MYSQL_PWD=\"\$$rv\" exec $cli -uroot -N -B"
}
my_converge() { # engine
  local e="$1" pw h net; on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || return 0
  log "$e hardening (idempotent)"
  load_env
  pw="$([ "$e" = mysql ] && echo "$MYSQL_ROOT_PASSWORD" || echo "$MARIADB_ROOT_PASSWORD")"
  net="$(my_host_of "$DOCKER_SUBNET")"
  for h in 127.0.0.1 "$net"; do
    printf "CREATE USER IF NOT EXISTS 'root'@'%s' IDENTIFIED BY %s;\nGRANT ALL PRIVILEGES ON *.* TO 'root'@'%s' WITH GRANT OPTION;\n" "$h" "$(sql_lit "$pw")" "$h"
  done | my_q "$e"
  if [ "$(printf "select count(*) from mysql.user where user='root' and host='%%';\n" | my_q "$e")" != 0 ]; then
    printf "DROP USER 'root'@'%%';\n" | my_q "$e"; echo "$e: removed root@'%'"
  fi
  if [ "$e" = mariadb ] && [ "$MARIADB_ED25519" = 1 ]; then
    printf "INSTALL SONAME 'auth_ed25519';\n" | my_q "$e" 2>/dev/null || true
  fi
  echo "$e: root on localhost, 127.0.0.1, $net only; local_infile=0$([ "$e" = mariadb ] && echo ', secure_file_priv set')$(tls_on && echo ', TLS required')"
  [ -z "$APP" ] || env_apply_engine "$e"
}
converge() { pg_converge; my_converge mysql; my_converge mariadb; pgbouncer_reload; }

# an existing compose network with other settings (subnet, IPv6) cannot be updated in
# place: stop the containers (volumes stay), remove the network, let compose recreate it
net_reset_if_changed() {
  local have want
  have="$(docker network inspect "$DOCKER_NETWORK" --format '{{.EnableIPv6}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)" || return 0
  want="false $DOCKER_SUBNET "
  [ "$have" = "$want" ] && return 0
  warn "network $DOCKER_NETWORK has '$have', want '$want': recreating it (containers restart, data stays)"
  dc down --remove-orphans >/dev/null 2>&1 || true
  docker ps -q --filter "network=$DOCKER_NETWORK" | xargs -r docker network disconnect -f "$DOCKER_NETWORK" 2>/dev/null || true
  docker network rm "$DOCKER_NETWORK" >/dev/null
}
start_stack() { # $1 = extra build flags. postgres first, then roles, then the rest
  log "Building and starting"
  net_reset_if_changed
  # shellcheck disable=SC2086
  if on "$ENABLE_POSTGRES"; then dc build --pull ${1:-}; fi
  # shellcheck disable=SC2046  # service names never contain spaces
  dc pull --ignore-buildable 2>/dev/null || dc pull $(dc config --services | grep -vx postgres || true)
  if on "$ENABLE_POSTGRES"; then
    dc up -d --wait --wait-timeout 300 --no-deps postgres
    PG_SU=""; pg_converge
  fi
  dc up -d --wait --wait-timeout 300 --remove-orphans
  my_converge mysql; my_converge mariadb; pgbouncer_reload
  retire_legacy_image
}
retire_legacy_image() { # old default/custom tags of the postgres image: untag (layers stay while used)
  on "$ENABLE_POSTGRES" || return 0
  local t; for t in $PG_IMAGE_LEGACY; do
    [ "$t" = "$PG_IMAGE" ] && continue
    docker image inspect "$t" >/dev/null 2>&1 && { docker image rm "$t" >/dev/null 2>&1 && echo "retired old image tag $t (now $PG_IMAGE)"; }
  done; return 0
}

firewall() {
  log "Firewall"
  if command -v ufw >/dev/null 2>&1; then
    for p in $(enabled_ports); do
      if ufw status | grep -Eq "^${p}/tcp[[:space:]]+ALLOW( IN)?[[:space:]]+${VPC_CIDR//./\\.}"; then
        echo "ufw: $p/tcp from $VPC_CIDR already allowed"
      else
        ufw allow proto tcp from "$VPC_CIDR" to any port "$p"
      fi
    done
    ufw status | grep -q "Status: active" || warn "ufw is installed but NOT active"
  else
    warn "ufw not installed - skipping firewall rules (ports are bound to $PRIVATE_IP only)"
  fi
}

cmd_status() { need_stack; dc ps; }

cmd_verify() {
  need_stack; load_env
  log "Verifying"
  dc up -d --wait --wait-timeout 180 >/dev/null 2>&1 || warn "not all services healthy yet"
  dc ps
  if on "$ENABLE_POSTGRES"; then
    dc exec -T postgres pg_isready -h 127.0.0.1 -U "$(pg_su)" -d "$PG_DB"
    echo "-- extensions in $PG_DB:"
    printf 'select extname, extversion from pg_extension order by 1;\n' | pg_q "$PG_DB" | tr '|' ' '
    echo "-- extensions in template1 (inherited by new DBs):"
    pg_val template1 "select string_agg(extname, ', ' order by extname) from pg_extension"
    echo "-- app login $PG_USER, direct TCP with password (127.0.0.1:5432):"
    dc exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
      psql -X -v ON_ERROR_STOP=1 "host=127.0.0.1 port=5432 user=$PG_USER dbname=$PG_DB sslmode=prefer" -tAc "select 'postgres ok, superuser=' || current_setting('is_superuser');"
  fi
  if on "$ENABLE_PGBOUNCER"; then
    echo "-- pgbouncer (docker network pgbouncer:5432, auth_query; host port $PRIVATE_IP:$PGBOUNCER_PORT):"
    dc exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
      psql -X -v ON_ERROR_STOP=1 "host=pgbouncer port=5432 user=$PG_USER dbname=$PG_DB sslmode=prefer" \
      -tAc "select 'pgbouncer ok: ' || current_user;"
  fi
  local e; for e in mysql mariadb; do
    on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || continue
    echo "-- $e:"
    [ "$(printf 'select 1;\n' | my_q "$e")" = 1 ] || die "$e: root login over the socket failed"
    printf 'select version();\n' | my_q "$e"
  done
  echo "ALL CHECKS PASSED"
}

cmd_env() { # [engine]: postgres (default when enabled), mysql, mariadb
  need_stack; load_env
  local e="${1:-$(engines | cut -d' ' -f1)}"
  echo "# paste into $WEB_ENV on the web server, then redeploy"
  echo "# (or save to a file and run src/shell/web/update-env-db.sh --from <file>)"
  case "$e" in
    postgres) on "$ENABLE_POSTGRES" || die "postgres is disabled"
      printf 'DB_CONNECTION=pgsql\nDB_HOST=%s\nDB_PORT=%s\nDB_DATABASE=%s\nDB_USERNAME=%s\nDB_PASSWORD=%s\n' \
        "$PRIVATE_IP" "$PG_PORT" "$PG_DB" "$PG_USER" "$PG_PASSWORD"
      tls_on && echo "DB_SSLMODE=require"
      on "$ENABLE_PGBOUNCER" && echo "# pooled alternative: DB_PORT=$PGBOUNCER_PORT (PgBouncer, $PGBOUNCER_POOL_MODE mode). Tenant creation and migrations: direct $PG_PORT."
      [ -z "$APP" ] || echo "# environments: env-creds <env> prints the per-environment block" ;;
    mysql|mariadb) on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || die "$e is disabled"
      echo "# no shared app user for $e: run  create-db <name> $e  (or env-creds <env> $e) and use its lines"
      printf 'DB_CONNECTION=%s\nDB_HOST=%s\nDB_PORT=%s\n' "$e" "$PRIVATE_IP" "$(engine_port "$e")" ;;
    *) die "usage: env [postgres|mysql|mariadb]" ;;
  esac
}

cmd_cron_install() {
  need_root
  local base="DBM_CONFIG=$DBM_CONFIG DB_DIR=$DB_DIR BACKUP_DIR=$BACKUP_DIR"
  {
    echo "# $TOOL_NAME $VERSION - generated by cron-install; re-run it after changing the config"
    echo "SHELL=/bin/bash"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "$CRON_TIME root $base $SELF backup --cron >> $CRON_LOG 2>&1"
    [ -n "$DOCTOR_CRON" ] && echo "$DOCTOR_CRON root $base DOCTOR_CONTEXT=cron $SELF doctor --alert >> $CRON_LOG 2>&1"
    [ -n "$RESTORE_TEST_CRON" ] && echo "$RESTORE_TEST_CRON root $base $SELF restore-test --cron >> $CRON_LOG 2>&1"
    if pitr_on; then
      echo "$PITR_FULL_CRON root $base $SELF pitr backup full >> $CRON_LOG 2>&1"
      echo "$PITR_DIFF_CRON root $base $SELF pitr backup diff >> $CRON_LOG 2>&1"
    fi
    if [ "$OFFSITE" != none ] && { on "$ENABLE_MYSQL" || on "$ENABLE_MARIADB"; }; then echo "$BINLOG_SHIP_CRON root $base $SELF binlog-ship >> $CRON_LOG 2>&1"; fi
    [ -n "$APP" ] && echo "40 4 * * * root $base $SELF purge-trash >> $CRON_LOG 2>&1"
  } > "$CRON_FILE"
  chmod 644 "$CRON_FILE"; echo "installed $CRON_FILE:"; cat "$CRON_FILE"
  if [ -d "$(dirname "$LOGROTATE_FILE")" ]; then
    printf '%s {\n  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n}\n' "$CRON_LOG" > "$LOGROTATE_FILE"
    echo "installed $LOGROTATE_FILE (weekly, 8 kept)"
  fi
}
cmd_cron_remove() { need_root; rm -f "$CRON_FILE" "$LOGROTATE_FILE"; echo "removed $CRON_FILE"; }
cmd_logs() { need_stack; dc logs -f --tail=200 "$@"; }

# env-init: the interactive setup wizard (or flags). Writes config KEY=VALUE lines only;
# nothing on the server changes until env-apply / upgrade. Exit 2 = a value is missing.
cmd_env_init() {
  local out="" dry=0 a k v
  local w_app="$APP" w_eng="" w_envs="" w_tenants="" w_protect="" w_prd="" w_pitr="" w_off="" w_tls="" w_mail="" w_allow=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) w_app="${2:-}"; shift ;; --engines) w_eng="${2:-}"; shift ;; --envs) w_envs="${2:-}"; shift ;;
      --tenant-dbs) w_tenants="${2:-}"; shift ;; --protect) w_protect="${2:-}"; shift ;; --prd-location) w_prd="${2:-}"; shift ;;
      --pitr) w_pitr="${2:-}"; shift ;; --offsite) w_off="${2:-}"; shift ;; --tls) w_tls="${2:-}"; shift ;;
      --alert-email) w_mail="${2:-}"; shift ;; --allow) w_allow="$w_allow ${2:-}"; shift ;;
      --out) out="${2:-}"; shift ;; --dry-run) dry=1 ;;
      *) die "unknown env-init option: $1" ;;
    esac; shift
  done
  ask() { # var prompt default validator
    local cur="${!1}" ans i
    if [ -n "$cur" ]; then "$4" "$cur" || die "invalid $2: '$cur'"; return 0; fi
    [ "$INTERACTIVE" = 1 ] || { [ -n "$3" ] && { printf -v "$1" '%s' "$3"; return 0; }; printf '!! env-init: missing --%s\n' "$2" >&2; exit 2; }
    for i in 1 2 3; do
      printf '%s [%s]: ' "$2" "$3" >/dev/tty; IFS= read -r ans </dev/tty || exit 2; ans="${ans:-$3}"
      if "$4" "$ans"; then printf -v "$1" '%s' "$ans"; return 0; fi; echo "  not valid, try again" >/dev/tty
    done; die "no valid $2"
  }
  v_app() { [[ "$1" =~ ^[a-z][a-z0-9]{1,19}$ ]]; }
  v_eng() { local x; for x in ${1//,/ }; do case "$x" in postgres|mysql|mariadb) ;; mongodb|mongo) echo "  MongoDB is off by design (docs/adr/0009-mongodb-off-by-default.md)" >&2; return 1 ;; *) return 1 ;; esac; done; }
  v_envs() { local x; [ -n "$1" ] || return 1; for x in ${1//,/ }; do in_list "$x" "$VALID_ENVS" || return 1; done; }
  v_sub() { [ "$1" = none ] || v_envs "$1"; }
  v_prd() { case "$1" in local|droplet|managed) ;; *) return 1 ;; esac; }
  v_pitr() { case "$1" in off|pgbackrest) ;; *) return 1 ;; esac; }
  v_off() { case "$1" in none|s3) ;; *) return 1 ;; esac; }
  v_tls() { case "$1" in off|require) ;; *) return 1 ;; esac; }
  v_mail() { [ "$1" = none ] || [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]]; }
  ask w_app app "" v_app
  ask w_eng engines postgres v_eng
  ask w_envs envs "tst,dev,stg,prd" v_envs
  ask w_tenants tenant-dbs "$w_envs" v_sub
  ask w_protect protect "$(in_list stg "${w_envs//,/ }" && echo stg,)prd" v_sub
  ask w_prd prd-location local v_prd
  ask w_pitr pitr "$(in_list postgres "${w_eng//,/ }" && echo pgbackrest || echo off)" v_pitr
  ask w_off offsite s3 v_off
  ask w_tls tls require v_tls
  ask w_mail alert-email none v_mail
  for a in $w_allow; do k="${a%%=*}"; v="${a#*=}"; { in_list "$k" "${w_envs//,/ } default" && valid_cidr "$v"; } || die "--allow wants env=CIDR (got $a)"; done
  in_list prd "${w_protect//,/ }" || ! in_list prd "${w_envs//,/ }" || warn "prd is not protected: destructive commands will not need --force-prod"
  local body
  body="$(
    echo "# ---- environments: written by env-init on $(date +%F) (no secrets) ----"
    echo "APP=$w_app"
    echo "ENABLE_POSTGRES=$(in_list postgres "${w_eng//,/ }" && echo 1 || echo 0)"
    echo "ENABLE_PGBOUNCER=$(in_list postgres "${w_eng//,/ }" && echo 1 || echo 0)"
    echo "ENABLE_MYSQL=$(in_list mysql "${w_eng//,/ }" && echo 1 || echo 0)"
    echo "ENABLE_MARIADB=$(in_list mariadb "${w_eng//,/ }" && echo 1 || echo 0)"
    echo "ENVS=\"${w_envs//,/ }\""
    echo "TENANT_ENVS=\"$([ "$w_tenants" = none ] || echo "${w_tenants//,/ }")\""
    echo "PROTECTED_ENVS=\"$([ "$w_protect" = none ] || echo "${w_protect//,/ }")\""
    echo "PRD_LOCATION=$w_prd"
    echo "PITR=$w_pitr"
    echo "OFFSITE=$w_off"
    [ "$w_off" = s3 ] && printf '%s\n' "#OFFSITE_ENDPOINT=https://ams3.digitaloceanspaces.com" "#OFFSITE_BUCKET=my-backups" "# credentials: $OFFSITE_CREDS_FILE (chmod 600): OFFSITE_ACCESS_KEY=..., OFFSITE_SECRET_KEY=..."
    [ "$w_pitr" = pgbackrest ] && [ "$w_off" != s3 ] && echo "PITR_REPO_TYPE=posix"
    echo "TLS_MODE=$w_tls"
    [ "$w_mail" = none ] || echo "ALERT_EMAIL=$w_mail"
    echo "RETENTION=\"$(in_list prd "${w_envs//,/ }" && echo 'daily=14 weekly=8 monthly=12 yearly=2' || echo 'daily=7 weekly=4 monthly=3')\""
    for a in $w_allow; do echo "ALLOW_${a%%=*}=${a#*=}"; done
  )"
  unset -f ask v_app v_eng v_envs v_sub v_prd v_pitr v_off v_tls v_mail
  if [ "$dry" = 1 ] || [ -z "$out" ]; then printf '%s\n' "$body"; [ "$dry" = 1 ] && echo "# dry run: nothing written"; return 0; fi
  if [ -f "$out" ]; then
    cp -p "$out" "$out.bak-$(date +%Y%m%d-%H%M%S)"
    local t; t="$(mktemp "$out.XXXX")"
    awk '/^# ---- environments: written by env-init/{skip=1} skip && /^$/{skip=0} !skip' "$out" > "$t"
    printf '\n%s\n\n' "$body" >> "$t"
    diff -u "$out" "$t" || true; chmod 600 "$t"; mv "$t" "$out"
  else (umask 077; printf '%s\n' "$body" > "$out"); fi
  echo "wrote $out. Next: sudo $SELF --config $out upgrade --dry-run, then upgrade, then env-apply"
}

# ---- databases and users: the approved privilege model ---------------------------
# docs/reference/privileges.md has the table and the reasons. In short, per database:
#   default app user  : connect, DDL in its own schema (migrations), DML; CREATEDB only
#                       with --tenants; never superuser/createrole/replication/bypassrls;
#                       cannot drop the database (an admin owns it).
#   read-only user    : connect + SELECT only.
# All SQL goes to the client on stdin, so generated passwords never appear in process
# arguments (ps), shell history or logs. Passwords print once to stdout, or go to a new
# chmod 600 file with --out FILE; they are never stored by this script.
U_ENGINE="" U_RO=0 U_OUT="" U_EXT="" U_OWNER="" U_TENANTS=0 U_ROUSER=0 U_FORCE_PROD=0 U_POS=()
parse_user_args() { # fills U_* from: [engine] [--engine E] [--readonly] [--out FILE] [--extensions a,b] [--owner U] [--tenants] [--readonly-user] [--force-prod]
  U_ENGINE="" U_RO=0 U_OUT="" U_EXT="" U_OWNER="" U_TENANTS=0 U_ROUSER=0 U_FORCE_PROD=0 U_POS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      postgres|pgsql|mysql|mariadb) U_ENGINE="${1/pgsql/postgres}" ;;
      mongodb|mongo) die "MongoDB is not managed by this tool (docs/adr/0009-mongodb-off-by-default.md)" ;;
      --engine) U_ENGINE="${2:-}"; shift ;;
      --readonly|--ro) U_RO=1 ;;
      --readwrite|--rw) U_RO=0 ;;
      --readonly-user) U_ROUSER=1 ;;
      --owner|--user) U_OWNER="${2:-}"; shift ;;
      --tenants|--allow-createdb) U_TENANTS=1 ;;
      --force-prod) U_FORCE_PROD=1 ;;
      --out) U_OUT="${2:-}"; shift ;;
      --extensions) U_EXT="${2:-}"; U_EXT="${U_EXT//,/ }"; shift ;;
      --yes|-y) ;;
      -*) die "unknown option: $1" ;;
      *) U_POS+=("$1") ;;
    esac; shift
  done
  [ -n "$U_ENGINE" ] || U_ENGINE="$(engines | cut -d' ' -f1)"
  case "$U_ENGINE" in
    postgres) on "$ENABLE_POSTGRES" || die "postgres is disabled" ;;
    mysql) on "$ENABLE_MYSQL" || die "mysql is disabled" ;;
    mariadb) on "$ENABLE_MARIADB" || die "mariadb is disabled" ;;
    *) die "engine must be postgres, mysql or mariadb (got $U_ENGINE)" ;;
  esac
}
valid_ident() { # name, what
  local max=63; [ "$U_ENGINE" = postgres ] || { max=64; [ "$2" = user ] && max=32; }
  [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]] && [ "${#1}" -le "$max" ] || die "bad $2 name '$1' (a-z 0-9 _, start with a letter or _, max $max)"
}
valid_exts() { local x; for x in $1; do [[ "$x" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad extension name: $x"; done; }
protected_db() { case "$1" in postgres|template0|template1|mysql|sys|information_schema|performance_schema|"$PG_DB") return 0 ;; esac; return 1; }
protected_user() { case "$1" in postgres|root|mysql|mariadb.sys|mysql.sys|mysql.session|mysql.infoschema|healthcheck|vsw_migrate|"$PG_USER"|"$PG_ADMIN_USER"|"$PGBOUNCER_AUTH_USER"|"$PGBOUNCER_ADMIN_USER") return 0 ;; esac; return 1; }
new_password() { openssl rand -hex 24; }
my_db_pat() { printf '%s' "${1//_/\\_}"; }   # GRANT treats _ and % as wildcards: escape _

pgbouncer_reload() { # new roles work through auth_query at once; RELOAD also refreshes config
  on "$ENABLE_PGBOUNCER" || return 0
  printf 'RELOAD;\n' | dc exec -T -e PGPASSWORD="${PGBOUNCER_ADMIN_PASSWORD:-}" pgbouncer \
    psql -X -q -h 127.0.0.1 -p 5432 -U "$PGBOUNCER_ADMIN_USER" -d pgbouncer -f - >/dev/null 2>&1 \
    || warn "PgBouncer RELOAD failed (it still picks up new roles via auth_query)"
}
engine_port() {
  case "$1" in
    postgres) if on "$ENABLE_PGBOUNCER"; then echo "$PGBOUNCER_PORT"; else echo "$PG_PORT"; fi ;;
    mysql) echo "$MYSQL_PORT" ;; mariadb) echo "$MARIADB_PORT" ;;
  esac
}
print_creds() { # engine db user password
  local conn="$1"; [ "$1" = postgres ] && conn=pgsql
  local body
  body="$(printf 'DB_CONNECTION=%s\nDB_HOST=%s\nDB_PORT=%s\nDB_DATABASE=%s\nDB_USERNAME=%s\nDB_PASSWORD=%s\n' \
    "$conn" "$PRIVATE_IP" "$(engine_port "$1")" "$2" "$3" "$4")"
  if [ "$1" = postgres ] && tls_on; then body="$body
DB_SSLMODE=require"; fi
  if [ "$1" = postgres ] && on "$ENABLE_PGBOUNCER"; then
    body="$body
# DB_PORT is PgBouncer; direct Postgres (tenant creation, migrations, admin) is $PG_PORT"
  fi
  if [ -n "$U_OUT" ]; then
    [ -e "$U_OUT" ] && die "refusing to overwrite $U_OUT"
    (umask 077; printf '%s\n' "$body" > "$U_OUT"); chmod 600 "$U_OUT"
    echo "# credentials for '$3' written to $U_OUT (chmod 600). Move them to the app's .env, then: shred -u $U_OUT"
  else
    echo "# credentials for '$3' - shown once, not stored on this server:"
    printf '%s\n' "$body"
  fi
}

# Postgres grants. $1 user, $2 db, $3 mode: owner | ro | rw (rw = DML only, no DDL)
pg_grant_sql() {
  local u="$1" d="$2" mode="$3" sowner
  [ -n "$(pg_val postgres "select 1 from pg_database where datname='$d'")" ] || die "database $d does not exist in postgres"
  sowner="$(pg_val "$d" "select pg_get_userbyid(nspowner) from pg_namespace where nspname='public'")"
  case "$mode" in
    owner) cat <<SQL
GRANT CONNECT, TEMPORARY ON DATABASE "$d" TO "$u";
ALTER SCHEMA public OWNER TO "$u";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SQL
    ;;
    ro) cat <<SQL
GRANT CONNECT ON DATABASE "$d" TO "$u";
GRANT USAGE ON SCHEMA public TO "$u";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$u";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$sowner" IN SCHEMA public GRANT SELECT ON TABLES TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$sowner" IN SCHEMA public GRANT SELECT ON SEQUENCES TO "$u";
SQL
    ;;
    rw) cat <<SQL
GRANT CONNECT, TEMPORARY ON DATABASE "$d" TO "$u";
GRANT USAGE ON SCHEMA public TO "$u";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$u";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$sowner" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$sowner" IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "$u";
SQL
    ;;
  esac
}
pg_role_sql() { # user password createdb(0/1) -> CREATE or ALTER a least-privilege login
  local attrs; attrs="NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS $([ "$3" = 1 ] && echo CREATEDB || echo NOCREATEDB)"
  if pg_role_exists "$1"; then printf 'ALTER ROLE "%s" LOGIN %s;\n' "$1" "$attrs"
  else printf "CREATE ROLE \"%s\" LOGIN %s PASSWORD %s;\n" "$1" "$attrs" "$(sql_lit "$2")"; fi
}
# MySQL/MariaDB grants: only on `db`.* (and `db\_%`.* with tenants). No global privileges,
# no GRANT OPTION, FILE, SUPER or PROCESS. DROP on db.* also allows DROP DATABASE of that
# one database (MySQL cannot split the two); see privileges.md.
MY_OWNER_PRIVS="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES, CREATE VIEW, SHOW VIEW, TRIGGER, CREATE ROUTINE, ALTER ROUTINE, EXECUTE, CREATE TEMPORARY TABLES, LOCK TABLES, EVENT"
MY_RW_PRIVS="SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE TEMPORARY TABLES, LOCK TABLES, SHOW VIEW"
MY_RO_PRIVS="SELECT, SHOW VIEW"
my_grant_sql() { # user db mode(owner|rw|ro) [tenant-pattern-db] [host]
  local privs h="${5:-$MY_APP_HOST}"
  case "$3" in owner) privs="$MY_OWNER_PRIVS" ;; rw) privs="$MY_RW_PRIVS" ;; *) privs="$MY_RO_PRIVS" ;; esac
  printf "GRANT %s ON \`%s\`.* TO '%s'@'%s';\n" "$privs" "$(my_db_pat "$2")" "$1" "$h"
  [ -z "${4:-}" ] || printf "GRANT %s ON \`%s\\_%%\`.* TO '%s'@'%s';\n" "$privs" "$(my_db_pat "$4")" "$1" "$h"
}
my_user_sql() { # user password [host]
  local h="${3:-$MY_APP_HOST}"
  if [ "$U_ENGINE" = mariadb ] && [ "$MARIADB_ED25519" = 1 ]; then
    printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED VIA ed25519 USING PASSWORD(%s);\n" "$1" "$h" "$(sql_lit "$2")"
  else printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY %s;\n" "$1" "$h" "$(sql_lit "$2")"; fi
}
pg_role_exists() { [ "$(printf "select 1 from pg_roles where rolname='%s';\n" "$1" | pg_q)" = 1 ]; }
my_user_exists() { [ "$(printf "select count(*) from mysql.user where user='%s';\n" "$1" | my_q "$2")" != 0 ]; }

cmd_list_dbs() { # [engine|all]
  need_root; need_stack; load_env
  local e list; list="$(engines)"; [ -n "${1:-}" ] && [ "$1" != all ] && list="$1"
  for e in $list; do
    log "$e databases"
    case "$e" in
      postgres) printf '%s\n' "select datname || '  owner=' || pg_get_userbyid(datdba) || '  size=' || pg_size_pretty(pg_database_size(datname)) || case when datallowconn then '' else '  (no connections: trash?)' end from pg_database where not datistemplate order by 1;" | pg_q ;;
      mysql|mariadb) echo "select concat(schema_name, '  size=', coalesce(round(sum(t.data_length+t.index_length)/1048576,1),0), 'MB') from information_schema.schemata s left join information_schema.tables t on t.table_schema=s.schema_name where schema_name not in ('mysql','sys','information_schema','performance_schema') group by schema_name order by 1;" | my_q "$e" ;;
      *) die "unknown engine: $e" ;;
    esac
  done
}
cmd_list_users() { # [engine|all]
  need_root; need_stack; load_env
  local e list; list="$(engines)"; [ -n "${1:-}" ] && [ "$1" != all ] && list="$1"
  for e in $list; do
    log "$e users"
    case "$e" in
      postgres) echo "select rolname || case when rolsuper then '  (superuser)' else '' end || case when rolcreatedb then '  (createdb)' else '' end || '  dbs=' || coalesce((select string_agg(datname, ',') from pg_database d where has_database_privilege(r.rolname, d.datname, 'CONNECT') and not datistemplate and datname<>'postgres'),'') from pg_roles r where rolcanlogin order by 1;" | pg_q ;;
      mysql|mariadb) echo "select concat(user,'@',host) from mysql.user where user not in ('mariadb.sys','mysql.sys','mysql.session','mysql.infoschema','healthcheck','') order by 1;" | my_q "$e" ;;
      *) die "unknown engine: $e" ;;
    esac
  done
}

# create-db <name> [engine] [--owner U] [--readonly-user] [--tenants] [--extensions a,b] [--out FILE]
# Every database gets its default app user (same name unless --owner), always.
cmd_create_db() {
  parse_user_args "$@"
  local name="${U_POS[0]:-}"; [ -n "$name" ] || die "usage: create-db <name> [engine] [--owner USER] [--readonly-user] [--tenants] [--extensions citext,hstore] [--out FILE]"
  local owner="${U_OWNER:-$name}" ro_user=$U_ROUSER tenants=$U_TENANTS
  valid_ident "$name" database; valid_ident "$owner" user; valid_exts "$U_EXT"
  protected_db "$name" && die "$name is reserved"
  protected_user "$owner" && die "$owner is reserved"
  [ -z "$U_EXT" ] || [ "$U_ENGINE" = postgres ] || die "--extensions is for postgres only"
  need_root; need_stack; load_env
  local pw x; pw="$(new_password)"
  case "$U_ENGINE" in
    postgres)
      [ -z "$(pg_val postgres "select 1 from pg_database where datname='$name'")" ] || die "database $name already exists in postgres"
      pg_role_exists "$owner" && die "role $owner already exists in postgres (pick --owner)"
      pg_role_sql "$owner" "$pw" "$tenants" | pg_q
      { printf 'CREATE DATABASE "%s" OWNER "%s";\n' "$name" "$(pg_su)"
        printf 'REVOKE ALL ON DATABASE "%s" FROM PUBLIC;\n' "$name"; } | pg_q
      pg_grant_sql "$owner" "$name" owner | pg_q "$name"
      # template1 already gave it PG_EXTENSIONS; --extensions adds more (needs superuser, so done here)
      if [ -n "$U_EXT" ]; then
        for x in $U_EXT; do printf 'CREATE EXTENSION IF NOT EXISTS "%s";\n' "$x"; done | pg_q "$name"
      fi
      echo "# extensions in $name: $(pg_val "$name" "select string_agg(extname, ' ' order by extname) from pg_extension")"
      pgbouncer_reload ;;
    mysql|mariadb)
      my_user_exists "$owner" "$U_ENGINE" && die "user $owner already exists in $U_ENGINE (pick --owner)"
      { printf 'CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$name"
        my_user_sql "$owner" "$pw"
        my_grant_sql "$owner" "$name" owner "$([ "$tenants" = 1 ] && echo "$name")"; } | my_q "$U_ENGINE" ;;
  esac
  local out="$U_OUT"
  echo "# database $name ($U_ENGINE): default app user $owner$([ "$tenants" = 1 ] && echo ", may create tenant DBs (${name}_*)")"
  print_creds "$U_ENGINE" "$name" "$owner" "$pw"
  if [ "$ro_user" = 1 ]; then
    [ -z "$out" ] || U_OUT="$out.readonly"
    cmd_create_user "${owner}_ro" "$name" "$U_ENGINE" --readonly ${U_OUT:+--out "$U_OUT"}
  fi
}

cmd_create_user() { # <user> <db> [engine] [--readonly|--readwrite] [--out FILE]
  parse_user_args "$@"
  local u="${U_POS[0]:-}" d="${U_POS[1]:-}" mode
  [ -n "$u" ] && [ -n "$d" ] || die "usage: create-user <user> <db> [engine] [--readonly|--readwrite] [--out FILE]"
  valid_ident "$u" user; valid_ident "$d" database; protected_user "$u" && die "$u is reserved"
  mode="$([ "$U_RO" = 1 ] && echo ro || echo rw)"
  need_root; need_stack; load_env
  local pw; pw="$(new_password)"
  case "$U_ENGINE" in
    postgres)
      pg_role_exists "$u" && die "role $u already exists"
      pg_role_sql "$u" "$pw" 0 | pg_q
      pg_grant_sql "$u" "$d" "$mode" | pg_q "$d"
      pgbouncer_reload ;;
    mysql|mariadb)
      my_user_exists "$u" "$U_ENGINE" && die "user $u already exists in $U_ENGINE"
      { my_user_sql "$u" "$pw"; my_grant_sql "$u" "$d" "$mode"; } | my_q "$U_ENGINE" ;;
  esac
  echo "# user $u on $d ($U_ENGINE): $([ "$U_RO" = 1 ] && echo read-only || echo 'read-write rows (no DDL)')"
  print_creds "$U_ENGINE" "$d" "$u" "$pw"
}

cmd_grant() { # <user> <db> [engine] [--readonly|--readwrite]
  parse_user_args "$@"
  local u="${U_POS[0]:-}" d="${U_POS[1]:-}" mode
  [ -n "$u" ] && [ -n "$d" ] || die "usage: grant <user> <db> [engine] [--readonly|--readwrite]"
  valid_ident "$u" user; valid_ident "$d" database; protected_user "$u" && die "refusing to change grants of $u"
  mode="$([ "$U_RO" = 1 ] && echo ro || echo rw)"
  need_root; need_stack; load_env
  case "$U_ENGINE" in
    postgres) pg_role_exists "$u" || die "no role $u"; pg_grant_sql "$u" "$d" "$mode" | pg_q "$d" ;;
    mysql|mariadb) my_user_exists "$u" "$U_ENGINE" || die "no user $u"; my_grant_sql "$u" "$d" "$mode" | my_q "$U_ENGINE" ;;
  esac
  echo "granted $u $([ "$U_RO" = 1 ] && echo read-only || echo read-write) on $d ($U_ENGINE)"
}

cmd_drop_db() { # <name> [engine] [--force-prod] (DESTRUCTIVE)
  parse_user_args "$@"; local d="${U_POS[0]:-}"
  [ -n "$d" ] || die "usage: drop-db <name> [engine] [--force-prod] [--yes]"
  valid_ident "$d" database; protected_db "$d" && die "refusing to drop protected database $d"
  need_root; need_stack; load_env
  local env; env="$(env_of_db "$d")"
  echo "About to DROP database $d on $U_ENGINE${env:+ (environment $env)}."
  guard_destructive "$d" "$env" "$U_FORCE_PROD"
  if [ -n "$env" ] && env_protected "$env"; then soft_drop "$U_ENGINE" "$d"; return 0; fi
  case "$U_ENGINE" in
    postgres) printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\n' "$d" | pg_q ;;
    mysql|mariadb) printf 'DROP DATABASE IF EXISTS `%s`;\n' "$d" | my_q "$U_ENGINE" ;;
  esac
  echo "dropped database $d ($U_ENGINE)"
}

cmd_drop_user() { # <user> [engine] (DESTRUCTIVE)
  parse_user_args "$@"; local u="${U_POS[0]:-}"
  [ -n "$u" ] || die "usage: drop-user <user> [engine] [--force-prod] [--yes]"
  valid_ident "$u" user; protected_user "$u" && die "refusing to drop protected user $u"
  need_root; need_stack; load_env
  local env; env="$(env_of_role "$u")"
  echo "About to DROP user $u on $U_ENGINE${env:+ (environment $env)}. Objects it owns are reassigned to $PG_ADMIN_USER (postgres)."
  guard_destructive "$u" "$env" "$U_FORCE_PROD"
  case "$U_ENGINE" in
    postgres)
      pg_role_exists "$u" || die "no role $u"
      local d; for d in $(echo "select datname from pg_database where datallowconn;" | pg_q); do
        printf 'REASSIGN OWNED BY "%s" TO "%s";\nDROP OWNED BY "%s";\n' "$u" "$(pg_su)" "$u" | pg_q "$d"
      done
      printf 'DROP ROLE "%s";\n' "$u" | pg_q; pgbouncer_reload ;;
    mysql|mariadb)
      local h; for h in $(printf "select host from mysql.user where user='%s';\n" "$u" | my_q "$U_ENGINE"); do
        printf "DROP USER IF EXISTS '%s'@'%s';\n" "$u" "$h"
      done | my_q "$U_ENGINE" ;;
  esac
  echo "dropped user $u ($U_ENGINE)"
}

cmd_rotate_password() { # <user> [engine] [--out FILE]
  parse_user_args "$@"; local u="${U_POS[0]:-}"
  [ -n "$u" ] || die "usage: rotate-password <user> [engine] [--out FILE]"
  valid_ident "$u" user
  local is_app=0; [ "$U_ENGINE" = postgres ] && [ "$u" = "$PG_USER" ] && is_app=1
  [ "$is_app" = 1 ] || ! protected_user "$u" || die "refusing to rotate $u here"
  need_root; need_stack; load_env
  [ "$is_app" = 1 ] && pg_legacy && die "$PG_USER is still the superuser; run upgrade (role split) first"
  local pw db h; pw="$(new_password)"
  case "$U_ENGINE" in
    postgres) pg_role_exists "$u" || die "no role $u"
      printf "ALTER ROLE \"%s\" PASSWORD %s;\n" "$u" "$(sql_lit "$pw")" | pg_q
      [ "$is_app" = 1 ] && set_env_key PG_PASSWORD "$pw"
      db="$(printf "select coalesce((select datname from pg_database where datname='%s'), '%s');\n" "$u" "$PG_DB" | pg_q)" ;;
    mysql|mariadb) my_user_exists "$u" "$U_ENGINE" || die "no user $u"
      for h in $(printf "select host from mysql.user where user='%s';\n" "$u" | my_q "$U_ENGINE"); do
        printf "ALTER USER '%s'@'%s' IDENTIFIED BY %s;\n" "$u" "$h" "$(sql_lit "$pw")"
      done | my_q "$U_ENGINE"; db="$u" ;;
  esac
  echo "# password rotated for $u ($U_ENGINE). Update the app's .env now; old password no longer works."
  print_creds "$U_ENGINE" "$db" "$u" "$pw"
}

# ---- upgrade -----------------------------------------------------------------
# upgrade = preflight -> plan (diff) -> confirm -> [snapshot] -> verified backup ->
# savepoint -> apply -> verify + doctor -> (auto-rollback on failure). Data is never
# restored automatically; `restore` stays a separate, confirmed command.
INTERACTIVE=0
is_interactive() { [ "$FORCE" != 1 ] && [ "${NONINTERACTIVE:-0}" != 1 ] && [ -t 0 ] && { : </dev/tty; } 2>/dev/null; }
ask_yn() { # prompt default(y|n) -> 0 yes / 1 no; strict answers, 3 tries
  local a i d="$2"
  if [ "$INTERACTIVE" != 1 ]; then die "needs an answer to: $1 (non-interactive: pass the matching flag)"; fi
  for i in 1 2 3; do
    printf '%s [%s] ' "$1" "$([ "$d" = y ] && echo Y/n || echo y/N)" >/dev/tty
    IFS= read -r a </dev/tty || die "no answer"
    a="$(printf '%s' "${a:-$d}" | tr '[:upper:]' '[:lower:]')"
    case "$a" in y|yes) echo "answer: yes"; return 0 ;; n|no) echo "answer: no"; return 1 ;; esac
    printf 'please answer y or n\n' >/dev/tty
  done
  die "no valid answer to: $1"
}
ask_word() { # WORD -> succeed only if typed exactly
  [ "$INTERACTIVE" = 1 ] || die "needs typed confirmation ($1); non-interactive runs can't give it"
  local a; printf 'Type %s to continue: ' "$1" >/dev/tty; IFS= read -r a </dev/tty || die "aborted"
  [ "$a" = "$1" ] || die "aborted (typed '$a', expected $1)"
}

valid_ipv4() { local IFS=. a b c d; [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r a b c d <<<"$1"; for x in "$a" "$b" "$c" "$d"; do [ "$x" -le 255 ] || return 1; done; }
valid_cidr() { [[ "$1" =~ ^(.+)/([0-9]{1,2})$ ]] || return 1; local ip="${BASH_REMATCH[1]}" bits="${BASH_REMATCH[2]}"; valid_ipv4 "$ip" && [ "$bits" -le 32 ]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
ip_to_int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
ip_in_cidr() { # ip cidr
  valid_ipv4 "$1" && valid_cidr "$2" || return 1
  local net="${2%/*}" bits="${2#*/}" mask
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  [ $(( $(ip_to_int "$1") & mask )) -eq $(( $(ip_to_int "$net") & mask )) ]
}
ip_private() { local c; for c in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do ip_in_cidr "$1" "$c" && return 0; done; return 1; }
extra_binds() { echo "${EXTRA_BIND_IPS//,/ }"; }
validate_config() { # strict: refuse anything ambiguous before touching the server
  local bad=0 v p seen=" "
  err() { printf '!! config: %s\n' "$*" >&2; bad=1; }
  valid_ipv4 "${PRIVATE_IP:-}" || err "PRIVATE_IP '${PRIVATE_IP:-}' is not an IPv4 address"
  case "${PRIVATE_IP:-}" in 0.0.0.0) err "PRIVATE_IP must not be 0.0.0.0 (would publish on every interface)" ;; esac
  [ -z "${EXPECTED_PRIVATE_IP:-}" ] || valid_ipv4 "$EXPECTED_PRIVATE_IP" || err "EXPECTED_PRIVATE_IP is not an IPv4 address"
  ip_private "${PRIVATE_IP:-0}" || err "PRIVATE_IP '${PRIVATE_IP:-}' is not a private (VPC) address; use EXTRA_BIND_IPS for anything else"
  for v in $(extra_binds); do
    valid_ipv4 "$v" || { err "EXTRA_BIND_IPS entry '$v' is not an IPv4 address"; continue; }
    case "$v" in 0.0.0.0|127.*) err "EXTRA_BIND_IPS must not contain $v" ;; esac
    [ "$v" = "${PRIVATE_IP:-}" ] && err "EXTRA_BIND_IPS repeats PRIVATE_IP $v"
    if ! ip_private "$v"; then
      [ "$ALLOW_PUBLIC_BIND" = 1 ] || err "EXTRA_BIND_IPS $v is public: set ALLOW_PUBLIC_BIND=1 on purpose (and a DO cloud firewall allowlist; Docker ports bypass ufw)"
      [ "$TLS_MODE" = require ] || err "EXTRA_BIND_IPS $v is public: TLS_MODE=require is mandatory"
    fi
  done
  case "$ALLOW_PUBLIC_BIND" in 0|1) ;; *) err "ALLOW_PUBLIC_BIND must be 0 or 1" ;; esac
  for v in ${PEER_REGIONS//,/ }; do [[ "$v" =~ ^[a-z]{3}[0-9]$ ]] || err "PEER_REGIONS entry '$v' is not a region slug (e.g. nyc1)"; done
  valid_cidr "$VPC_CIDR" || err "VPC_CIDR '$VPC_CIDR' is not a CIDR (e.g. 10.0.0.0/20)"
  for v in PG_PORT PGBOUNCER_PORT MYSQL_PORT MARIADB_PORT ADMINER_PORT; do valid_port "${!v}" || err "$v '${!v}' is not a port (1-65535)"; done
  for p in $(enabled_ports) $(on "$ENABLE_ADMINER" && echo "$ADMINER_PORT"); do
    case "$seen" in *" $p "*) err "port $p is used twice" ;; esac; seen="$seen$p "
  done
  for v in KEEP MIN_FREE_MB PG_MAX_CONNECTIONS PGBOUNCER_POOL_SIZE PGBOUNCER_MAX_CLIENT_CONN; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || err "$v '${!v}' must be a whole number"
  done
  [ "$KEEP" -ge 1 ] 2>/dev/null || err "KEEP must be at least 1"
  for v in PG_USER PG_DB; do [[ "${!v}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || err "$v '${!v}' must match ^[a-z_][a-z0-9_]*\$"; done
  for v in PG_IMAGE PG_BASE_IMAGE PGBOUNCER_IMAGE MYSQL_IMAGE MARIADB_IMAGE ADMINER_IMAGE; do
    [[ "${!v}" =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]{64})?$ ]] || err "$v '${!v}' is not an image reference"
    [[ "${!v}" =~ :latest$ ]] && err "$v uses :latest; pin a version"
  done
  [[ "$DB_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] && [ "$DB_DIR" != / ] || err "DB_DIR '$DB_DIR' must be an absolute path"
  case "$TLS_MODE" in off|require) ;; *) err "TLS_MODE must be off or require" ;; esac
  case "$PITR" in off|pgbackrest) ;; *) err "PITR must be off or pgbackrest" ;; esac
  case "$PITR_REPO_TYPE" in s3|posix) ;; *) err "PITR_REPO_TYPE must be s3 or posix" ;; esac
  case "$OFFSITE" in none|s3) ;; *) err "OFFSITE must be none or s3" ;; esac
  [ "$OFFSITE" = none ] || [ -n "$OFFSITE_BUCKET" ] || err "OFFSITE=s3 needs OFFSITE_BUCKET"
  case "$PGBOUNCER_POOL_MODE" in session|transaction) ;; *) err "PGBOUNCER_POOL_MODE must be session or transaction" ;; esac
  case "$PG_APP_CREATEDB" in 0|1) ;; *) err "PG_APP_CREATEDB must be 0 or 1" ;; esac
  valid_cidr "$DOCKER_SUBNET" || err "DOCKER_SUBNET '$DOCKER_SUBNET' is not a CIDR"
  for v in PG_ADMIN_USER PGBOUNCER_AUTH_USER PGBOUNCER_ADMIN_USER; do [[ "${!v}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || err "$v '${!v}' is not a valid role name"; done
  [ "$PG_ADMIN_USER" != "$PG_USER" ] || err "PG_ADMIN_USER must differ from PG_USER"
  if [ -n "$RETENTION" ]; then for v in $RETENTION; do [[ "$v" =~ ^(daily|weekly|monthly|yearly)=[0-9]+$ ]] || err "RETENTION item '$v' (want daily=N weekly=N monthly=N yearly=N)"; done; fi
  for v in BINLOG_DAYS PITR_DAYS FRESH_BACKUP_MIN TRASH_DAYS BACKUP_MAX_AGE_H TLS_DAYS; do [[ "${!v}" =~ ^[0-9]+$ ]] || err "$v must be a whole number"; done
  unset -f err
  [ "$bad" = 0 ] || die "config invalid - fix it (see config/db-server.env.example); nothing was changed"
  echo "config ok"
}

# lock: one mutating run at a time (cron backup, a second ssh session, ...)
DBM_LOCK="${DBM_LOCK:-$( [ -d /run/lock ] && echo /run/lock || echo /tmp )/docker-db-server-manager.lock}"
LOCK_HELD=0
take_lock() {
  if mkdir "$DBM_LOCK" 2>/dev/null; then :
  else
    local pid; pid="$(cat "$DBM_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "another run is in progress (pid $pid, lock $DBM_LOCK); wait for it to finish"
    fi
    warn "removing stale lock $DBM_LOCK (pid ${pid:-?} is gone)"; rm -rf "$DBM_LOCK"; mkdir "$DBM_LOCK" || die "cannot take lock $DBM_LOCK"
  fi
  echo "$$" > "$DBM_LOCK/pid"; LOCK_HELD=1
  trap 'finish_log; release_lock' EXIT
}
release_lock() { [ "$LOCK_HELD" = 1 ] && rm -rf "$DBM_LOCK"; LOCK_HELD=0; }

# logging with secrets redacted (values of *PASSWORD*/*TOKEN*/*SECRET* keys, -p<pw>, long hex, bearer tokens)
DBM_LOG="${DBM_LOG:-/var/log/docker-db-server-manager.log}"
redact() { perl -pe 'BEGIN{$|=1} s/((?:PASSWORD|TOKEN|SECRET|PASS)[A-Za-z0-9_]*["\x27]?\s*[=:]\s*["\x27]?)[^\s"\x27]+/$1***/gi; s/(\s-p)(?!\s)\S+/$1***/g; s/(?<!sha256:)\b[0-9a-f]{32,}\b/***/g; s/(Bearer\s+)\S+/$1***/gi'; }
LOG_PID=""
finish_log() { # flush the log pipe before exit so the last lines (often the error) are not lost
  [ -n "$LOG_PID" ] || return 0
  exec 1>&3 2>&4 3>&- 4>&-; wait "$LOG_PID" 2>/dev/null || true; LOG_PID=""
}
start_log() {
  (umask 077; touch "$DBM_LOG") 2>/dev/null || { warn "cannot write $DBM_LOG; logging to stdout only"; return 0; }
  chmod 600 "$DBM_LOG"
  exec 3>&1 4>&2
  exec > >(redact | tee -a "$DBM_LOG") 2>&1
  LOG_PID=$!; trap 'finish_log; release_lock' EXIT
  echo "---- $(date '+%F %T %z') $TOOL_NAME $VERSION ${1:-run} on $(hostname) (log: $DBM_LOG)"
}

installed_version() { sed -n '1s/^# generated by .* \([0-9][0-9.]*\) - .*/\1/p' "$DB_DIR/docker-compose.yml" 2>/dev/null | grep . || echo unknown; }

preflight() {
  log "Preflight"
  validate_config
  echo "manager: $VERSION, installed stack: $(installed_version)"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then die "Docker is not running (systemctl status docker)"; fi
  docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
  echo "docker ok: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  local free; free="$(df -Pm "$DB_DIR" | awk 'NR==2 {print $4}')"
  [ "${free:-0}" -ge "$((MIN_FREE_MB * 2))" ] || die "only ${free}MB free on $DB_DIR; upgrade needs $((MIN_FREE_MB * 2))MB (2 x MIN_FREE_MB) for backup + images"
  echo "disk ok: ${free}MB free"
  need_stack; load_env
  local line bad=0 ports
  while IFS=$'\t' read -r svc state health; do
    [ -n "$svc" ] || continue
    if [ "$state" != running ] || { [ -n "$health" ] && [ "$health" != healthy ]; }; then
      echo "  $svc: $state ${health:-} - NOT HEALTHY"; bad=1
    else echo "  $svc: $state ${health:-}"; fi
  done < <(dc ps -a --format '{{.Service}}{{"\t"}}{{.State}}{{"\t"}}{{.Health}}')
  if [ "$bad" = 1 ]; then
    warn "some containers are not healthy before the upgrade"
    ask_yn "Continue anyway (the upgrade may fix it; rollback returns to this state)?" n || die "aborted; nothing changed"
  fi
  ports="$(dc ps --format '{{.Service}} {{.Ports}}')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if echo "$line" | grep -qE '(^| |,)(0\.0\.0\.0|\[?::\]?):[0-9]+->'; then echo "  PUBLIC port: $line - PROBLEM"; bad=2; fi
    case "$line" in adminer*) echo "$line" | grep -qE '127\.0\.0\.1:[0-9]+->' || { echo "  adminer not on loopback: $line - PROBLEM"; bad=2; } ;; esac
  done <<<"$ports"
  [ "$bad" = 2 ] && warn "a port is published on every interface now; the upgrade rewrites bindings to $PRIVATE_IP / 127.0.0.1"
  echo "preflight ok"
}

PLAN_DIR=""
PLAN_FILES="docker-compose.yml stack.env postgres/Dockerfile postgres/init/10-extensions.sql postgres/conf/pg_hba.conf postgres/conf/entry.sh postgres/conf/pgbackrest.conf"
render_to() { local REAL_DB_DIR="$DB_DIR" DB_DIR="$1"; ensure_env_keys "$1/.env" >/dev/null; write_files >/dev/null; }
plan() { # renders the new files next to the old ones and prints a diff; returns 0 if anything changes
  log "Plan (dry run): what would change"
  PLAN_DIR="$(mktemp -d)"; chmod 700 "$PLAN_DIR"
  cp -p "$DB_DIR/.env" "$PLAN_DIR/.env"
  [ -d "$DB_DIR/tls" ] && cp -Rp "$DB_DIR/tls" "$PLAN_DIR/tls"
  ( render_to "$PLAN_DIR" )
  local f changed=1
  for f in $PLAN_FILES; do
    [ -e "$DB_DIR/$f" ] || [ -e "$PLAN_DIR/$f" ] || continue
    if ! diff -q "$DB_DIR/$f" "$PLAN_DIR/$f" >/dev/null 2>&1; then
      changed=0; echo "--- $f"
      if [ -e "$DB_DIR/$f" ]; then diff -u "$DB_DIR/$f" "$PLAN_DIR/$f" 2>/dev/null | tail -n +3 || true
      elif [ -e "$PLAN_DIR/$f" ]; then echo "(new file)"; sed 's/^/+/' "$PLAN_DIR/$f"
      else echo "(removed)"; fi
    fi
  done
  local k; for k in $ENV_KEYS; do grep -q "^$k=" "$DB_DIR/.env" || { changed=0; echo "--- .env: would add $k (generated, not shown)"; }; done
  if on "$ENABLE_POSTGRES" && stack_up postgres; then
    pg_legacy && { changed=0; echo "--- postgres: role split: $PG_USER (superuser) -> $PG_ADMIN_USER (admin) + $PG_USER (app, no superuser). Ends $PG_USER sessions briefly."; }
  fi
  for k in mysql mariadb; do
    on "$( [ "$k" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" && stack_up "$k" || continue
    [ "$(printf "select count(*) from mysql.user where user='root' and host='%%';\n" | my_q "$k" 2>/dev/null)" = 0 ] || { changed=0; echo "--- $k: drop root@'%' (root stays on localhost, 127.0.0.1, $DOCKER_SUBNET)"; }
  done
  [ "$changed" = 0 ] || echo "no changes"
  return "$changed"
}
SAVE=""
savepoint() {
  SAVE="$DB_DIR/upgrade-saves/$(date +%Y%m%d-%H%M%S)"
  log "Savepoint $SAVE"
  (umask 077; mkdir -p "$SAVE")
  chmod 700 "$DB_DIR/upgrade-saves"
  cp -p "$DB_DIR/docker-compose.yml" "$DB_DIR/.env" "$SAVE/"
  [ -f "$DB_DIR/stack.env" ] && cp -p "$DB_DIR/stack.env" "$SAVE/"
  [ -d "$DB_DIR/postgres" ] && cp -Rp "$DB_DIR/postgres" "$SAVE/postgres"
  [ -d "$DB_DIR/pgbouncer" ] && cp -Rp "$DB_DIR/pgbouncer" "$SAVE/pgbouncer-dir"
  local prev="${DBM_PREV_SCRIPT:-$SELF.prev}"; [ -f "$prev" ] || prev="$SELF"
  if [ -f "$prev" ]; then cp -p "$prev" "$SAVE/manager.sh"; else warn "manager script not found at $SELF; savepoint has no script copy"; fi
  local cfg="${DBM_PREV_CONFIG:-$DBM_CONFIG.prev}"; [ -f "$cfg" ] || cfg="$DBM_CONFIG"
  [ -f "$cfg" ] && cp -p "$cfg" "$SAVE/manager.conf"
  if on "$ENABLE_PGBOUNCER" && dc ps --status running --services 2>/dev/null | grep -qx pgbouncer; then
    mkdir -p "$SAVE/pgbouncer"
    dc exec -T pgbouncer cat /etc/pgbouncer/pgbouncer.ini > "$SAVE/pgbouncer/pgbouncer.ini" 2>/dev/null || true
    dc exec -T pgbouncer cat /etc/pgbouncer/userlist.txt > "$SAVE/pgbouncer/userlist.txt" 2>/dev/null || true
  fi
  local s; for s in $(dc ps --services 2>/dev/null); do
    printf '%s %s\n' "$s" "$(docker inspect -f '{{.Image}}' "$(dc ps -q "$s")" 2>/dev/null)"
  done > "$SAVE/images.txt"
  if on "$ENABLE_POSTGRES"; then # pin the running postgres image so a rebuild cannot garbage-collect it
    local pimg; pimg="$(awk '$1=="postgres"{print $2}' "$SAVE/images.txt")"
    [ -z "$pimg" ] || docker tag "$pimg" "vsw/postgres:pre-upgrade" || warn "could not pin the current postgres image"
  fi
  installed_version > "$SAVE/version"
  if on "$ENABLE_POSTGRES" && stack_up postgres && pg_legacy; then echo legacy > "$SAVE/pg-roles"; else echo split > "$SAVE/pg-roles"; fi
  chmod -R go-rwx "$SAVE"
  find "$DB_DIR/upgrade-saves" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +6 | while read -r old; do rm -rf "$old"; done
  find "$SAVE" -maxdepth 2 | sed 's/^/  /'
}

rollback() {
  log "ROLLBACK to $SAVE"
  cd "$DB_DIR"
  # undo the role split first, while the new postgres is still running (old files expect the old roles)
  if [ "$(cat "$SAVE/pg-roles" 2>/dev/null)" = legacy ] && stack_up postgres; then
    PG_SU=""; [ "$(pg_val postgres "select count(*) from pg_roles where rolname='$PG_ADMIN_USER' and oid = 10" 2>/dev/null)" = 1 ] \
      && { ( set -e; pg_role_split_rollback ) || warn "role split rollback failed: see docs/tools/db-server-manager.md#role-split"; }
  fi
  cp -p "$SAVE/docker-compose.yml" "$SAVE/.env" ./
  [ -f "$SAVE/stack.env" ] && cp -p "$SAVE/stack.env" ./
  [ -d "$SAVE/postgres" ] && { rm -rf ./postgres; cp -Rp "$SAVE/postgres" ./postgres; }
  if [ -d "$SAVE/pgbouncer-dir" ]; then rm -rf ./pgbouncer; cp -Rp "$SAVE/pgbouncer-dir" ./pgbouncer; else rm -rf ./pgbouncer; fi
  if on "$ENABLE_POSTGRES"; then # put the old locally built image back under its (possibly old) tag
    local old img; img="$(set -a; . ./stack.env; echo "$PG_IMAGE")"
    old="vsw/postgres:pre-upgrade"; docker image inspect "$old" >/dev/null 2>&1 || old="$(awk '$1=="postgres"{print $2}' "$SAVE/images.txt")"
    [ -z "$old" ] || docker tag "$old" "$img" || warn "could not retag old postgres image"
  fi
  dc up -d --wait --wait-timeout 300 --remove-orphans || warn "containers did not all become healthy after rollback"
  # the saved files may use another network; drop the new one if nothing uses it any more
  grep -q "name: \${DOCKER_NETWORK}" docker-compose.yml 2>/dev/null || docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
  [ -f "$SAVE/manager.sh" ] && ! cmp -s "$SAVE/manager.sh" "$SELF" && cp -p "$SAVE/manager.sh" "$SELF.rolled-back-from" 2>/dev/null || true
  set +e; ( set -e; PG_SU=""; cmd_verify ); local rc=$?; set -e
  if [ "$rc" = 0 ]; then echo "ROLLBACK OK: the stack is back on the saved files ($SAVE). Data was not touched."
  else echo "ROLLBACK VERIFY FAILED. Data is untouched; backup: $LAST_BACKUP. Next: logs, then restore $LAST_BACKUP all (confirmed) or the snapshot."; fi
  return 1
}

LAST_BACKUP=""
cmd_upgrade() { # [--dry-run] [--yes|--non-interactive] [--snapshot|--snapshot-taken|--no-snapshot]
  need_root
  local dry=0 a
  for a in "$@"; do case "$a" in
    --dry-run) dry=1 ;; --yes|-y) FORCE=1 ;; --non-interactive) NONINTERACTIVE=1 ;;
    --snapshot) SNAP_MODE=yes ;; --snapshot-taken) SNAP_MODE=taken ;; --no-snapshot) SNAP_MODE=no ;;
    *) die "unknown upgrade option: $a (see help)" ;; esac; done
  if is_interactive; then INTERACTIVE=1; fi
  [ "$dry" = 1 ] || start_log upgrade
  banner upgrade
  [ "$dry" = 1 ] || snapshot_policy_check
  preflight
  # a stack built with another image tag (old default or a custom one) gets the new tag; the old one is retired after success
  local prev_img; prev_img="$(sed -n 's/^PG_IMAGE=//p' "$DB_DIR/stack.env" 2>/dev/null)"
  [ -z "$prev_img" ] || [ "$prev_img" = "$PG_IMAGE" ] || in_list "$prev_img" "$PG_IMAGE_LEGACY" || PG_IMAGE_LEGACY="$PG_IMAGE_LEGACY $prev_img"
  local changes=0 cur; cur="$(installed_version)"
  if plan; then changes=1; fi
  if [ "$changes" = 0 ] && [ "$cur" = "$VERSION" ]; then
    rm -rf "$PLAN_DIR"; echo "already up to date ($VERSION); nothing to do"; return 0
  fi
  if [ "$dry" = 1 ]; then rm -rf "$PLAN_DIR"; echo "dry run: nothing changed"; return 0; fi
  if [ "$INTERACTIVE" = 1 ]; then ask_yn "Apply these changes ($cur -> $VERSION)?" n || { rm -rf "$PLAN_DIR"; die "aborted; nothing changed"; }
  elif [ "$FORCE" != 1 ]; then rm -rf "$PLAN_DIR"; die "non-interactive upgrade needs --yes to apply"; fi
  rm -rf "$PLAN_DIR"
  snapshot_step
  cmd_backup
  LAST_BACKUP="$(newest_backup)"
  verify_backup "$LAST_BACKUP"
  savepoint
  log "Apply"
  set +e
  ( set -e; ensure_env_keys; load_env; write_files; start_stack; firewall; [ "${DBM_TEST_FAIL_APPLY:-0}" != 1 ] || { echo "test hook: forced apply failure"; exit 1; } ); local rc=$?
  if [ "$rc" = 0 ]; then ( set -e; load_env; PG_SU=""; cmd_verify; [ "${DBM_TEST_FAIL_VERIFY:-0}" != 1 ] || { echo "test hook: forced verify failure"; exit 1; } ); rc=$?; fi
  if [ "$rc" = 0 ]; then ( set -e; load_env; PG_SU=""; DOCTOR_CONTEXT=upgrade cmd_doctor ); rc=$?; fi
  set -e
  if [ "$rc" != 0 ]; then
    warn "apply/verify/doctor failed (exit $rc) - rolling back automatically"
    rollback || true
    die "UPGRADE FAILED and was rolled back. Log: $DBM_LOG  Savepoint: $SAVE  Backup: $LAST_BACKUP"
  fi
  log "UPGRADE OK: $cur -> $VERSION"
  echo "backup: $LAST_BACKUP"; echo "savepoint: $SAVE (manual rollback: see docs/tools/db-server-manager.md#upgrade)"; echo "log: $DBM_LOG"
  [ "$OFFSITE" != none ] || echo "next: configure off-site copies (OFFSITE=s3) - backups on the same droplet die with it"
  [ -f "$CRON_FILE" ] && grep -q 'doctor --alert' "$CRON_FILE" || echo "next: cron-install (backups, doctor --alert, restore tests$(pitr_on && echo ', PITR'))"
}

snapshot_token() { # never echoed or logged
  if [ -n "${DIGITALOCEAN_TOKEN:-}" ]; then printf '%s' "$DIGITALOCEAN_TOKEN"; return 0; fi
  local f="${DO_TOKEN_FILE:-/root/.config/digitalocean-token}"
  [ -f "$f" ] || return 1
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ] || { warn "$f must be chmod 600; ignoring it"; return 1; }
  tr -d ' \n\r' < "$f"
}
take_snapshot() { # server-side, DigitalOcean API; waits for completion
  local tok id act st i name
  tok="$(snapshot_token)" || return 1
  id="$(curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/id 2>/dev/null)" || { warn "not a DigitalOcean droplet (no metadata)"; return 1; }
  name="$(hostname)-pre-upgrade-$(date +%Y%m%d-%H%M%S)"
  log "DigitalOcean snapshot $name (droplet $id)"
  act="$(curl -fsS -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"type\":\"snapshot\",\"name\":\"$name\"}" "https://api.digitalocean.com/v2/droplets/$id/actions" \
    | sed -n 's/.*"action":{"id":\([0-9]*\).*/\1/p')"
  [ -n "$act" ] || { warn "snapshot request failed"; return 1; }
  for i in $(seq 1 240); do
    st="$(curl -fsS -H "Authorization: Bearer $tok" "https://api.digitalocean.com/v2/actions/$act" | sed -n 's/.*"status":"\([a-z-]*\)".*/\1/p')"
    case "$st" in completed) echo "snapshot completed: $name"; return 0 ;; errored) warn "snapshot errored"; return 1 ;; esac
    sleep 15
  done
  warn "snapshot still running after 60 min"; return 1
}
SNAP_MODE=ask   # ask | yes | no | taken
snapshot_policy_check() { # fail fast, before any work, if a non-interactive run can't decide
  [ "$INTERACTIVE" = 1 ] && return 0
  case "$SNAP_MODE" in
    ask) if snapshot_token >/dev/null; then SNAP_MODE=yes
         else die "non-interactive upgrade: no DigitalOcean token for a snapshot. Pass --snapshot-taken (done elsewhere) or --no-snapshot (accept: verified backup only)"; fi ;;
  esac
}
snapshot_step() {
  case "$SNAP_MODE" in
    taken) echo "snapshot: taken before this run (remote-run/doctl)"; return 0 ;;
    no) warn "snapshot skipped (--no-snapshot): rollback relies on the saved files and the verified backup"; return 0 ;;
    yes) take_snapshot || die "snapshot failed; nothing changed (re-run with --no-snapshot to proceed without one)"; return 0 ;;
  esac
  if snapshot_token >/dev/null; then
    if ask_yn "Take a DigitalOcean snapshot first (recommended; a few minutes)?" y; then
      take_snapshot || { warn "snapshot failed"; ask_word CONTINUE; }
    fi
  else
    warn "no DigitalOcean token (DIGITALOCEAN_TOKEN or ${DO_TOKEN_FILE:-/root/.config/digitalocean-token}, chmod 600) and no --snapshot-taken."
    warn "A snapshot is the only undo for host-level damage (disk, Docker engine). The backup and saved files cover the database stack."
    ask_word CONTINUE
  fi
}

# ---- environments: <app>_<env> databases, roles, guard rails ----------------------
# Naming contract (docs/reference/naming.md):
#   database  <app>_<env>            tenants  <app>_<env>_t_<id>
#   roles     <app>_<env>_owner (NOLOGIN, owns schema public)   <app>_<env>_app (login)
#             <app>_<env>_ro (login, SELECT)   <app>_<env>_migrator (login, only with ENV_MIGRATOR=1)
# With ENV_MIGRATOR=0 the app role is a member of _owner (runs migrations = "default app
# user" in privileges.md). With ENV_MIGRATOR=1 only _migrator is; _app gets DML only.
# Passwords: $ENV_SECRETS_DIR/<env>.env (0600), generated once, printed only by env-creds.
VALID_ENVS="tst dev trn stg prd"
local_envs() { local e out=""; for e in $ENVS; do [ "$e" = prd ] && [ "$PRD_LOCATION" != local ] && continue; out="$out $e"; done; echo "${out# }"; }
env_db() { echo "${APP}_$1"; }
env_role() { echo "${APP}_$1_$2"; } # env kind(owner|app|ro|migrator)
env_allow() { local v="ALLOW_$1"; echo "${!v:-${ALLOW_default:-$VPC_CIDR}}"; }
env_protected() { in_list "$1" "$PROTECTED_ENVS"; }
env_tenants() { in_list "$1" "$TENANT_ENVS"; }
env_of_db() { # db -> env name or ""
  [ -n "$APP" ] || return 0
  local e; for e in $ENVS; do
    case "$1" in "${APP}_$e"|"${APP}_${e}_t_"*|"${APP}_${e}__trash_"*) echo "$e"; return 0 ;; esac
  done
}
env_of_role() { [ -n "$APP" ] || return 0; local e; for e in $ENVS; do case "$1" in "${APP}_${e}_"*) echo "$e"; return 0 ;; esac; done; }
validate_envs() {
  [ -n "$APP" ] || return 0
  [[ "$APP" =~ ^[a-z][a-z0-9]{1,19}$ ]] || die "APP '$APP' must be 2-20 chars, a-z 0-9, start with a letter (no _: it separates env and tenant)"
  local e; for e in $ENVS $TENANT_ENVS $PROTECTED_ENVS; do in_list "$e" "$VALID_ENVS" || die "unknown environment '$e' (allowed: $VALID_ENVS)"; done
  for e in $TENANT_ENVS; do in_list "$e" "$ENVS" || die "'$e' is in TENANT_ENVS but not in ENVS"; done   # PROTECTED_ENVS may name envs this server lacks
  in_list prd "$ENVS" && ! in_list prd "$PROTECTED_ENVS" && warn "prd is not in PROTECTED_ENVS: destructive commands on prd will not ask for --force-prod"
  case "$PRD_LOCATION" in local|droplet|managed) ;; *) die "PRD_LOCATION must be local, droplet or managed" ;; esac
  for e in $(local_envs); do local a; a="$(env_allow "$e")"; for a in ${a//,/ }; do valid_cidr "$a" || die "ALLOW_$e: '$a' is not a CIDR"; done; done
}
env_secret() { # env key -> value; generates and stores it on first use (never printed here)
  local f="$ENV_SECRETS_DIR/$1.env" v
  (umask 077; mkdir -p "$ENV_SECRETS_DIR"); chmod 700 "$ENV_SECRETS_DIR"
  [ -f "$f" ] || (umask 077; : > "$f")
  chmod 600 "$f"
  v="$(sed -n "s/^$2=//p" "$f" | head -1)"
  if [ -z "$v" ]; then v="$(new_password)"; (umask 077; printf '%s=%s\n' "$2" "$v" >> "$f"); fi
  printf '%s' "$v"
}

# Postgres SQL for one environment, idempotent. $2 = "local" (run here) or "print" (managed/
# other host: no secrets, passwords via \password).
env_pg_sql() { # env mode
  local e="$1" db o a r m cd attrs; db="$(env_db "$e")"; o="$(env_role "$e" owner)"; a="$(env_role "$e" app)"; r="$(env_role "$e" ro)"; m="$(env_role "$e" migrator)"
  cd=NOCREATEDB; env_tenants "$e" && cd=CREATEDB
  attrs="NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS"
  role() { # name login(1/0) extra password
    printf "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '%s') THEN CREATE ROLE \"%s\"; END IF; END \$\$;\n" "$1" "$1"
    printf 'ALTER ROLE "%s" %s %s %s;\n' "$1" "$([ "$2" = 1 ] && echo LOGIN || echo NOLOGIN)" "$attrs" "$3"
    [ -z "${4:-}" ] || printf "ALTER ROLE \"%s\" PASSWORD %s;\n" "$1" "$(sql_lit "$4")"
  }
  local pa="" pr="" pm=""
  if [ "$2" = local ]; then pa="$(env_secret "$e" APP_PASSWORD)"; pr="$(env_secret "$e" RO_PASSWORD)"; [ "$ENV_MIGRATOR" = 1 ] && pm="$(env_secret "$e" MIGRATOR_PASSWORD)"; fi
  role "$o" 0 NOCREATEDB
  role "$a" 1 "$cd" "$pa"
  role "$r" 1 NOCREATEDB "$pr"
  if [ "$ENV_MIGRATOR" = 1 ]; then role "$m" 1 NOCREATEDB "$pm"; printf 'GRANT "%s" TO "%s";\nREVOKE "%s" FROM "%s";\n' "$o" "$m" "$o" "$a"
  else printf 'GRANT "%s" TO "%s";\n' "$o" "$a"; fi
  unset -f role
  printf "SELECT 'CREATE DATABASE \"%s\" OWNER \"' || current_user || '\"' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '%s')\\\\gexec\n" "$db" "$db"
  printf 'REVOKE ALL ON DATABASE "%s" FROM PUBLIC;\nGRANT CONNECT, TEMPORARY ON DATABASE "%s" TO "%s", "%s";\nGRANT CONNECT ON DATABASE "%s" TO "%s";\n' "$db" "$db" "$a" "$o" "$db" "$r"
  [ "$ENV_MIGRATOR" = 1 ] && printf 'GRANT CONNECT, TEMPORARY ON DATABASE "%s" TO "%s";\n' "$db" "$m"
  printf '\\c "%s"\n' "$db"
  printf 'ALTER SCHEMA public OWNER TO "%s";\nREVOKE ALL ON SCHEMA public FROM PUBLIC;\nGRANT USAGE ON SCHEMA public TO "%s", "%s";\n' "$o" "$a" "$r"
  printf 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO "%s";\nGRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO "%s";\n' "$r" "$r"
  printf 'ALTER DEFAULT PRIVILEGES FOR ROLE "%s" IN SCHEMA public GRANT SELECT ON TABLES TO "%s";\n' "$o" "$r"
  printf 'ALTER DEFAULT PRIVILEGES FOR ROLE "%s" IN SCHEMA public GRANT SELECT ON SEQUENCES TO "%s";\n' "$o" "$r"
  if [ "$ENV_MIGRATOR" = 1 ]; then
    printf 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "%s";\nGRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "%s";\n' "$a" "$a"
    printf 'ALTER DEFAULT PRIVILEGES FOR ROLE "%s" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "%s";\n' "$o" "$a"
    printf 'ALTER DEFAULT PRIVILEGES FOR ROLE "%s" IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "%s";\n' "$o" "$a"
  fi
  [ "$2" = print ] && printf -- "-- then set passwords:  \\\\password %s   \\\\password %s\n" "$a" "$r"
  return 0
}
env_my_sql() { # env engine mode
  local e="$1" db a r pa="" pr="" t=""; db="$(env_db "$e")"; a="$(env_role "$e" app)"; r="$(env_role "$e" ro)"
  [ "${#a}" -le 32 ] || die "MySQL user name $a is longer than 32 characters; shorten APP"
  if [ "$3" = local ]; then pa="$(env_secret "$e" "MY_APP_PASSWORD_$2")"; pr="$(env_secret "$e" "MY_RO_PASSWORD_$2")"; else pa="CHANGE_ME"; pr="CHANGE_ME"; fi
  env_tenants "$e" && t="${db}_t"
  printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$db"
  local U_ENGINE="$2"
  my_user_sql "$a" "$pa"; my_user_sql "$r" "$pr"
  printf "ALTER USER '%s'@'%s' IDENTIFIED BY %s;\nALTER USER '%s'@'%s' IDENTIFIED BY %s;\n" "$a" "$MY_APP_HOST" "$(sql_lit "$pa")" "$r" "$MY_APP_HOST" "$(sql_lit "$pr")"
  my_grant_sql "$a" "$db" owner "$t"; my_grant_sql "$r" "$db" ro "$t"
}
env_apply_engine() { # engine: create/repair every local environment (idempotent)
  [ -n "$APP" ] || return 0
  validate_envs
  local e
  for e in $(local_envs); do
    case "$1" in
      postgres) env_pg_sql "$e" local | pg_q postgres >/dev/null ;;
      mysql|mariadb) env_my_sql "$e" "$1" local | my_q "$1" ;;
    esac
    echo "  env $e: $(env_db "$e") on $1 ok$(env_tenants "$e" && echo " (tenants ${APP}_${e}_t_*)")$(env_protected "$e" && echo ' [protected]')"
  done
}
cmd_env_apply() { need_root; need_stack; load_env; [ -n "$APP" ] || die "APP is not set (run env-init first)"; validate_envs
  log "Environments for $APP: $(local_envs)$( [ "$PRD_LOCATION" != local ] && echo " (prd is $PRD_LOCATION: env-sql prd)")"
  local x; for x in $(engines); do env_apply_engine "$x"; done; pgbouncer_reload
  local f; f="$(dirname "$DBM_CONFIG")/pg_hba.reload"; : "$f"
  if on "$ENABLE_POSTGRES"; then write_pg_hba "$DB_DIR/postgres/conf/pg_hba.conf"; printf 'SELECT pg_reload_conf();\n' | pg_q >/dev/null; echo "  pg_hba.conf rewritten and reloaded"; fi
}
cmd_env_sql() { # <env> [engine]: SQL for a host this script does not manage (prd managed/droplet)
  [ -n "$APP" ] || die "APP is not set"; validate_envs
  local e="${1:-}" x="${2:-postgres}"; in_list "$e" "$ENVS" || die "usage: env-sql <env> [postgres|mysql|mariadb]"
  echo "-- $APP $e on $x: run as an admin on the target server (no passwords in this output)"
  case "$x" in postgres) env_pg_sql "$e" print ;; mysql|mariadb) env_my_sql "$e" "$x" print ;; *) die "bad engine $x" ;; esac
}
cmd_env_list() {
  [ -n "$APP" ] || { echo "no environment layout (APP is empty)"; return 0; }
  validate_envs
  local e; printf '%-5s %-22s %-9s %-9s %-10s %s\n' ENV DATABASE TENANTS PROTECTED WHERE ALLOW
  for e in $ENVS; do
    printf '%-5s %-22s %-9s %-9s %-10s %s\n' "$e" "$(env_db "$e")" "$(env_tenants "$e" && echo yes || echo no)" \
      "$(env_protected "$e" && echo yes || echo no)" "$([ "$e" = prd ] && echo "$PRD_LOCATION" || echo local)" "$(env_allow "$e")"
  done
}
cmd_env_creds() { # <env> [engine] [--out FILE]: the app's DB_* block (prints secrets: use --out)
  parse_user_args "$@"; local e="${U_POS[0]:-}"; in_list "$e" "$(local_envs)" || die "usage: env-creds <env> [engine] [--out FILE]"
  need_root; need_stack; load_env
  local key=APP_PASSWORD; [ "$U_ENGINE" = postgres ] || key="MY_APP_PASSWORD_$U_ENGINE"
  [ -f "$ENV_SECRETS_DIR/$e.env" ] || die "no secrets for $e yet (env-apply)"
  print_creds "$U_ENGINE" "$(env_db "$e")" "$(env_role "$e" app)" "$(env_secret "$e" "$key")"
}

# guard rails for destructive commands
newest_backup() { find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | tail -1; }
backup_age_min() { local b; b="$(newest_backup)"; [ -n "$b" ] || { echo 999999; return; }
  echo $(( ($(date +%s) - $(stat -c %Y "$b" 2>/dev/null || stat -f %m "$b")) / 60 )); }
guard_destructive() { # target env force(0/1)
  local t="$1" e="$2" f="${3:-0}"
  [ "${WORKBENCH_FORCE_PROD:-0}" = 1 ] && f=1
  if [ -n "$e" ] && env_protected "$e"; then
    [ "$f" = 1 ] || die "$t belongs to protected environment '$e': add --force-prod (and type '$e' when asked)"
    if [ "${WORKBENCH_CONFIRM:-}" = "$e" ]; then echo "confirmed by WORKBENCH_CONFIRM=$e"
    elif [ "$INTERACTIVE" = 1 ]; then ask_word "$e"
    else die "protected '$e': type the environment name interactively, or set WORKBENCH_CONFIRM=$e"; fi
    local age; age="$(backup_age_min)"
    if [ "$age" -gt "$FRESH_BACKUP_MIN" ]; then echo "newest backup is ${age} min old (limit $FRESH_BACKUP_MIN): taking one now"; cmd_backup; fi
    verify_backup "$(newest_backup)"
  else
    confirm DROP
  fi
}
soft_drop() { # engine db: protected envs never lose data in one step
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  case "$1" in
    postgres)
      { printf 'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = %s;\n' "$(sql_lit "$2")"
        printf 'ALTER DATABASE "%s" RENAME TO "%s__trash_%s";\nALTER DATABASE "%s__trash_%s" ALLOW_CONNECTIONS false;\n' "$2" "$2" "$ts" "$2" "$ts"; } | pg_q >/dev/null
      echo "soft-dropped: $2 is now ${2}__trash_$ts (no connections). purge-trash removes it after $TRASH_DAYS days."
      echo "undo: ALTER DATABASE \"${2}__trash_$ts\" ALLOW_CONNECTIONS true; ALTER DATABASE \"${2}__trash_$ts\" RENAME TO \"$2\";" ;;
    mysql|mariadb)
      local d="$BACKUP_DIR/dropped"; (umask 077; mkdir -p "$d")
      local cli=mysqldump rv=MYSQL_ROOT_PASSWORD; [ "$1" = mariadb ] && cli=mariadb-dump rv=MARIADB_ROOT_PASSWORD
      dc exec -T "$1" sh -c "MYSQL_PWD=\"\$$rv\" exec $cli -uroot --databases '$2' --single-transaction --routines --events --triggers" | gzip > "$d/$2-$ts.sql.gz"
      gzip -cd "$d/$2-$ts.sql.gz" | tail -c 500 | grep -q 'Dump completed' || die "dump of $2 failed; NOT dropped"
      chmod 600 "$d/$2-$ts.sql.gz"
      printf 'DROP DATABASE `%s`;\n' "$2" | my_q "$1"
      echo "dropped $2 after a dump to $d/$2-$ts.sql.gz (kept $DROPPED_DUMP_DAYS days)" ;;
  esac
}
cmd_purge_trash() { # [--dry-run]
  need_root; need_stack; load_env
  local dry=0; [ "${1:-}" = --dry-run ] && dry=1
  local cutoff; cutoff="$(date -d "-$TRASH_DAYS days" +%Y%m%d%H%M%S 2>/dev/null || date -v-"${TRASH_DAYS}"d +%Y%m%d%H%M%S)"
  if on "$ENABLE_POSTGRES"; then
    local d; for d in $(printf "select datname from pg_database where datname like '%%\\_\\_trash\\_%%';\n" | pg_q); do
      [ "${d##*__trash_}" \< "$cutoff" ] || continue
      if [ "$dry" = 1 ]; then echo "would drop $d"; else printf 'DROP DATABASE "%s" WITH (FORCE);\n' "$d" | pg_q; echo "purged $d"; fi
    done
  fi
  if [ -d "$BACKUP_DIR/dropped" ]; then
    if [ "$dry" = 1 ]; then find "$BACKUP_DIR/dropped" -name '*.sql.gz' -mtime +"$DROPPED_DUMP_DAYS" -print
    else find "$BACKUP_DIR/dropped" -name '*.sql.gz' -mtime +"$DROPPED_DUMP_DAYS" -print -delete; fi
  fi
  return 0
}

# ---- backups -------------------------------------------------------------------
my_sh() { # engine script: run sh in the container with root's password in MYSQL_PWD (socket login)
  local rv=MYSQL_ROOT_PASSWORD; [ "$1" = mariadb ] && rv=MARIADB_ROOT_PASSWORD
  dc exec -T "$1" sh -c "export MYSQL_PWD=\"\$$rv\"; $2"
}
MY_SYS_DBS="'mysql','sys','information_schema','performance_schema'"
manifest() { # what a restore must reproduce: per database, the number of user tables
  if on "$ENABLE_POSTGRES"; then
    local d; for d in $(echo "select datname from pg_database where datallowconn and not datistemplate order by 1;" | pg_q); do
      printf 'postgres %s %s\n' "$d" "$(pg_val "$d" "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema') and n.nspname not like 'pg\_%'")"
    done
  fi
  local e; for e in mysql mariadb; do
    on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || continue
    echo "select s.schema_name, count(t.table_name) from information_schema.schemata s left join information_schema.tables t on t.table_schema=s.schema_name and t.table_type='BASE TABLE' where s.schema_name not in ($MY_SYS_DBS) group by s.schema_name order by 1;" \
      | my_q "$e" | awk -v e="$e" '{print e, $1, $2}'
  done
}
# GFS: keep the newest backup of each of the last N days / ISO weeks / months / years.
# stdin: backup names (YYYYMMDD-HHMMSS), any order. stdout: names to keep.
iso_week() { date -d "$1" +%G%V 2>/dev/null || date -j -f %Y%m%d "$1" +%G%V; }
gfs_keep() { # "daily=14 weekly=8 monthly=12 yearly=2"
  local spec="$1" d=0 w=0 m=0 y=0 kv n day k
  for kv in $spec; do case "$kv" in daily=*) d="${kv#*=}" ;; weekly=*) w="${kv#*=}" ;; monthly=*) m="${kv#*=}" ;; yearly=*) y="${kv#*=}" ;; *) die "bad RETENTION item: $kv" ;; esac; done
  local seen_d=" " seen_w=" " seen_m=" " seen_y=" " cd=0 cw=0 cm=0 cy=0 keep
  while read -r n; do
    [[ "$n" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
    day="${n%-*}"; keep=0
    if [ "$cd" -lt "$d" ] && ! in_list "$day" "$seen_d"; then seen_d="$seen_d$day "; cd=$((cd + 1)); keep=1; fi
    k="$(iso_week "$day")"
    if [ "$cw" -lt "$w" ] && ! in_list "$k" "$seen_w"; then seen_w="$seen_w$k "; cw=$((cw + 1)); keep=1; fi
    k="${day:0:6}"
    if [ "$cm" -lt "$m" ] && ! in_list "$k" "$seen_m"; then seen_m="$seen_m$k "; cm=$((cm + 1)); keep=1; fi
    k="${day:0:4}"
    if [ "$cy" -lt "$y" ] && ! in_list "$k" "$seen_y"; then seen_y="$seen_y$k "; cy=$((cy + 1)); keep=1; fi
    [ "$keep" = 0 ] || echo "$n"
  done < <(sort -r)
}
prune_backups() {
  local all keep old
  all="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' -exec basename {} \; | sort -r)"
  if [ -n "$RETENTION" ]; then keep="$(printf '%s\n' "$all" | gfs_keep "$RETENTION")"
  else keep="$(printf '%s\n' "$all" | head -n "$KEEP")"; fi
  keep="$keep
$(printf '%s\n' "$all" | head -1)"   # never delete the newest
  for old in $all; do printf '%s\n' "$keep" | grep -qx "$old" || { echo "pruning $old"; rm -rf "${BACKUP_DIR:?}/$old"; }; done
}

cmd_backup() { # [--cron]
  need_root; need_stack; load_env
  local ts free dest tmp cron=0; [ "${1:-}" = --cron ] && cron=1
  if [ "$cron" = 1 ]; then trap 'rc=$?; [ $rc = 0 ] || notify backup fail "backup failed (exit $rc), see '"$CRON_LOG"'"' EXIT; fi
  ts="$(date +%Y%m%d-%H%M%S)"; dest="$BACKUP_DIR/$ts"; tmp="$BACKUP_DIR/.partial-$ts"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  free="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
  [ "${free:-0}" -ge "$MIN_FREE_MB" ] || die "only ${free}MB free in $BACKUP_DIR (MIN_FREE_MB=$MIN_FREE_MB); not starting a backup"
  rm -rf "$BACKUP_DIR"/.partial-*
  (umask 077; mkdir -p "$tmp")
  log "Backing up to $dest"
  if on "$ENABLE_POSTGRES"; then
    dc exec -T postgres pg_dumpall -U "$(pg_su)" --clean --if-exists | gzip > "$tmp/postgres.sql.gz"
  fi
  # MySQL/MariaDB: user databases only (system schemas are skipped so a restore never
  # overwrites root/users; .env passwords stay valid). Users + grants go to grants-*.sql.gz.
  local users_sql="select concat(\"'\",user,\"'@'\",host,\"'\") from mysql.user where user not in ('root','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','healthcheck','')"
  local e cli dump; for e in mysql mariadb; do
    on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || continue
    cli=mysql dump=mysqldump; [ "$e" = mariadb ] && cli=mariadb dump=mariadb-dump
    my_sh "$e" "DBS=\$($cli -uroot -NBe \"select schema_name from information_schema.schemata where schema_name not in ($MY_SYS_DBS)\"); [ -z \"\$DBS\" ] && exit 0; exec $dump -uroot --databases \$DBS --single-transaction --routines --events --triggers" | gzip > "$tmp/$e.sql.gz"
    printf '%s;\n' "$users_sql" | my_q "$e" | while read -r u; do printf 'show create user %s;\nshow grants for %s;\n' "$u" "$u" | my_q "$e" | sed 's/$/;/'; done | gzip > "$tmp/grants-$e.sql.gz"
  done
  manifest > "$tmp/manifest.txt"
  local f; for f in "$tmp"/*.gz; do gzip -t "$f"; done
  (cd "$tmp" && sha256sum ./*.gz manifest.txt 2>/dev/null > SHA256SUMS || shasum -a 256 ./*.gz manifest.txt > SHA256SUMS)
  chmod 600 "$tmp"/*
  mv "$tmp" "$dest"
  verify_backup "$dest"
  ls -lh "$dest"
  prune_backups
  stamp backup "$dest"
  if [ "$OFFSITE" != none ]; then offsite_upload "$dest" || { notify offsite fail "off-site copy of $ts failed"; die "off-site copy failed (local backup $dest is fine)"; }; fi
  if [ -n "$BACKUP_HOOK" ]; then
    log "Backup hook"
    bash -c "$BACKUP_HOOK" _ "$dest" || die "BACKUP_HOOK failed (the local backup in $dest is fine)"
  fi
  notify backup ok "backup $ts ok$( [ "$OFFSITE" != none ] && echo ' + off-site')"
  echo "backup ok: $dest"
}
verify_backup() { # $1 dir: every enabled engine present, gzip ok, dump trailer present, checksums
  local d="$1"; [ -n "$d" ] && [ -d "$d" ] || die "no backup to verify"
  on "$ENABLE_POSTGRES" && { gzip -cd "$d/postgres.sql.gz" | tail -c 2000 | grep -q 'dump complete' || die "postgres dump in $d is incomplete"; }
  local e; for e in mysql mariadb; do
    if [ "$e" = mysql ]; then on "$ENABLE_MYSQL" || continue; else on "$ENABLE_MARIADB" || continue; fi
    [ -f "$d/$e.sql.gz" ] || die "$e dump missing in $d"
    if [ -n "$(gzip -cd "$d/$e.sql.gz" | head -c 1)" ]; then
      gzip -cd "$d/$e.sql.gz" | tail -c 500 | grep -q 'Dump completed' || die "$e dump in $d is incomplete"
    fi
  done
  if [ -f "$d/SHA256SUMS" ]; then
    (cd "$d" && { sha256sum -c --quiet SHA256SUMS 2>/dev/null || shasum -a 256 -c --quiet SHA256SUMS; }) >/dev/null || die "checksum mismatch in $d"
  fi
  echo "backup verified: $d"
}

cmd_restore() { # <dir> [engine|all]
  need_root; need_stack; load_env
  local force=0 a pos=(); for a in "$@"; do case "$a" in --force-prod) force=1 ;; *) pos+=("$a") ;; esac; done
  local src="${pos[0]:-}" what="${pos[1]:-all}" pe=""
  { [ -n "$src" ] && [ -d "$src" ]; } || die "usage: restore <backup-dir> [postgres|mysql|mariadb|all]"
  case "$what" in postgres|mysql|mariadb|all) ;; *) die "unknown target: $what" ;; esac
  [ "$what" = all ] || in_list "$what" "$(engines)" || die "$what is disabled"
  verify_backup "$src"
  banner "restore $what from $src"
  echo "This OVERWRITES current $what data with the backup (every database on the server, all environments)."
  # protected environment on this server -> the same guard rails as drop-db (needs --force-prod)
  if [ -n "$APP" ]; then for a in $(local_envs); do env_protected "$a" && { pe="$a"; break; }; done; fi
  if [ -n "$pe" ]; then guard_destructive "server" "$pe" "$force"; else confirm RESTORE; fi
  want() { { [ "$what" = all ] || [ "$what" = "$1" ]; } && in_list "$1" "$(engines)" \
    && { [ -f "$src/$1.sql.gz" ] || { warn "no $1.sql.gz in $src - skipping"; return 1; }; }; }
  if want postgres; then
    log "postgres"
    if on "$ENABLE_PGBOUNCER"; then dc stop pgbouncer >/dev/null; fi
    # skip role DDL for the roles we manage (admin we are connected as; app/pgbouncer roles are
    # re-asserted by converge), so a pre-1.4 dump cannot make the app a superuser again
    local skip; skip="$PG_USER|$PG_ADMIN_USER|$PGBOUNCER_AUTH_USER|$PGBOUNCER_ADMIN_USER"
    gunzip -c "$src/postgres.sql.gz" | grep -vE "^(DROP|CREATE|ALTER) ROLE (IF EXISTS )?\"?($skip)\"?( |;)" \
      | dc exec -T postgres psql -X -q -v ON_ERROR_STOP=0 -U "$(pg_su)" -d postgres >/dev/null
    pg_converge
    if on "$ENABLE_PGBOUNCER"; then dc up -d --wait pgbouncer; fi
  fi
  local e; for e in mysql mariadb; do
    want "$e" || continue; log "$e"
    gunzip -c "$src/$e.sql.gz" | my_q "$e" >/dev/null
  done
  echo "restore done (users/grants are in grants-*.sql.gz if you need them)"
}

# ---- restore test: load the newest backup into throwaway containers ------------
# No network (--network none), random passwords, removed afterwards. Compares the
# manifest (tables per database). Cron: RESTORE_TEST_CRON via cron-install.
cmd_restore_test() { # [dir] [--cron]
  need_root; need_stack; load_env
  local src="" cron=0 a; for a in "$@"; do case "$a" in --cron) cron=1 ;; *) src="$a" ;; esac; done
  [ -n "$src" ] || src="$(newest_backup)"
  [ -n "$src" ] && [ -d "$src" ] || die "no backup to test"
  log "Restore test of $src"
  verify_backup "$src"
  local tag="vsw-rt-$$" pw got want rc=0 e img
  pw="$(new_password)"
  # explicit cleanup on every path: a RETURN trap does not fire reliably here, and nightly
  # cron runs would otherwise leave throwaway containers (and their RAM) behind
  cleanup_rt() { docker rm -f "$tag-postgres" "$tag-mysql" "$tag-mariadb" >/dev/null 2>&1 || true; rm -f "/tmp/$tag.got"; }
  rt_die() { cleanup_rt; die "$@"; }
  docker ps -aq --filter name=vsw-rt- 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true   # leftovers of older versions
  : > "/tmp/$tag.got"
  rt_wait() { local i; for i in $(seq 1 "$((RESTORE_TEST_TIMEOUT / 2))"); do docker exec "$1" sh -c "$2" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
  if on "$ENABLE_POSTGRES" && [ -f "$src/postgres.sql.gz" ]; then
    docker run -d --name "$tag-postgres" --network none -e POSTGRES_PASSWORD="$pw" -e POSTGRES_USER="$PG_ADMIN_USER" -e POSTGRES_DB=postgres "$PG_IMAGE" >/dev/null
    rt_wait "$tag-postgres" "pg_isready -U $PG_ADMIN_USER -h 127.0.0.1" || rt_die "restore test: postgres did not start"
    sleep 2
    gunzip -c "$src/postgres.sql.gz" | grep -vE "^(DROP|CREATE|ALTER) ROLE (IF EXISTS )?\"?$PG_ADMIN_USER\"?( |;)" | docker exec -i "$tag-postgres" psql -X -q -v ON_ERROR_STOP=0 -U "$PG_ADMIN_USER" -d postgres >/dev/null 2>&1 || true
    for d in $(docker exec "$tag-postgres" psql -X -U "$PG_ADMIN_USER" -d postgres -tAc "select datname from pg_database where datallowconn and not datistemplate order by 1"); do
      printf 'postgres %s %s\n' "$d" "$(docker exec "$tag-postgres" psql -X -U "$PG_ADMIN_USER" -d "$d" -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema') and n.nspname not like 'pg\_%'")"
    done >> "/tmp/$tag.got"
  fi
  for e in mysql mariadb; do
    on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || continue
    [ -f "$src/$e.sql.gz" ] || continue
    img="$MYSQL_IMAGE"; local cli=mysql pv=MYSQL_ROOT_PASSWORD; [ "$e" = mariadb ] && img="$MARIADB_IMAGE" cli=mariadb pv=MARIADB_ROOT_PASSWORD
    docker run -d --name "$tag-$e" --network none -e "$pv=$pw" "$img" >/dev/null
    rt_wait "$tag-$e" "MYSQL_PWD='$pw' $cli -uroot -e 'select 1'" || rt_die "restore test: $e did not start"
    gunzip -c "$src/$e.sql.gz" | docker exec -i -e MYSQL_PWD="$pw" "$tag-$e" $cli -uroot || { warn "$e load reported errors"; rc=1; }
    docker exec -e MYSQL_PWD="$pw" "$tag-$e" $cli -uroot -NBe "select s.schema_name, count(t.table_name) from information_schema.schemata s left join information_schema.tables t on t.table_schema=s.schema_name and t.table_type='BASE TABLE' where s.schema_name not in ($MY_SYS_DBS) group by s.schema_name order by 1" \
      | awk -v e="$e" '{print e, $1, $2}' >> "/tmp/$tag.got"
  done
  want="$( [ -f "$src/manifest.txt" ] && sort "$src/manifest.txt")"; got="$(sort "/tmp/$tag.got")"; cleanup_rt
  if [ -z "$want" ]; then warn "no manifest in $src (older backup): only checked that it loads"; printf '%s\n' "$got" | while IFS= read -r l; do echo "  $l"; done
  elif [ "$want" != "$got" ]; then
    echo "manifest mismatch (expected vs restored):"; diff <(echo "$want") <(echo "$got") | sed 's/^/  /' || true; rc=1
  else echo "manifest matches: $(echo "$want" | wc -l | tr -d ' ') databases"; fi
  if [ "$rc" = 0 ]; then stamp restore-test "$src"; notify restore-test ok "restore test of $(basename "$src") ok"; echo "restore test OK"
  else notify restore-test fail "restore test of $(basename "$src") FAILED"; [ "$cron" = 1 ] && exit 1; die "restore test FAILED"; fi
}

# ---- off-site copies (encrypted before upload) ---------------------------------
offsite_key() {
  if [ "$OFFSITE_ENCRYPTION" = age ]; then [ -f "$OFFSITE_KEY_FILE" ] || die "age recipients file $OFFSITE_KEY_FILE missing"; return 0; fi
  if [ ! -f "$OFFSITE_KEY_FILE" ]; then
    (umask 077; mkdir -p "$(dirname "$OFFSITE_KEY_FILE")"; openssl rand -base64 48 > "$OFFSITE_KEY_FILE")
    warn "created $OFFSITE_KEY_FILE (chmod 600). COPY IT OFF THIS SERVER (password manager): without it the off-site copies cannot be decrypted."
  fi
  local m; m="$(stat -c %a "$OFFSITE_KEY_FILE" 2>/dev/null || stat -f %Lp "$OFFSITE_KEY_FILE")"; [ "$m" = 600 ] || die "$OFFSITE_KEY_FILE must be chmod 600"
}
offsite_encrypt() { # stdin -> stdout
  if [ "$OFFSITE_ENCRYPTION" = age ]; then age -R "$OFFSITE_KEY_FILE"
  else openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$OFFSITE_KEY_FILE"; fi
}
offsite_decrypt() {
  if [ "$OFFSITE_ENCRYPTION" = age ]; then die "age: decrypt with your identity: age -d -i KEY FILE | tar -xz"
  else openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$OFFSITE_KEY_FILE"; fi
}
offsite_env() { # export tool credentials for one command (values never printed)
  local OFFSITE_ACCESS_KEY="" OFFSITE_SECRET_KEY="" PITR_CIPHER_PASS=""
  offsite_creds || die "missing $OFFSITE_CREDS_FILE (chmod 600) with OFFSITE_ACCESS_KEY and OFFSITE_SECRET_KEY"
  [ -n "$OFFSITE_BUCKET" ] || die "OFFSITE_BUCKET is not set"
  export RCLONE_CONFIG_VSW_TYPE=s3 RCLONE_CONFIG_VSW_PROVIDER=Other RCLONE_CONFIG_VSW_ENDPOINT="$OFFSITE_ENDPOINT" \
    RCLONE_CONFIG_VSW_REGION="$OFFSITE_REGION" RCLONE_CONFIG_VSW_ACCESS_KEY_ID="$OFFSITE_ACCESS_KEY" \
    RCLONE_CONFIG_VSW_SECRET_ACCESS_KEY="$OFFSITE_SECRET_KEY" RCLONE_CONFIG_VSW_NO_CHECK_BUCKET=true
  export AWS_ACCESS_KEY_ID="$OFFSITE_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$OFFSITE_SECRET_KEY" AWS_DEFAULT_REGION="$OFFSITE_REGION"
}
remote_put() { # local remote-name
  case "$OFFSITE_TOOL" in
    rclone) rclone copyto --s3-no-check-bucket "$1" "vsw:$OFFSITE_BUCKET/$OFFSITE_PREFIX/$2" ;;
    aws) aws s3 cp --only-show-errors ${OFFSITE_ENDPOINT:+--endpoint-url "$OFFSITE_ENDPOINT"} "$1" "s3://$OFFSITE_BUCKET/$OFFSITE_PREFIX/$2" ;;
    *) die "OFFSITE_TOOL must be rclone or aws" ;;
  esac
}
remote_get() { # remote-name local
  case "$OFFSITE_TOOL" in
    rclone) rclone copyto "vsw:$OFFSITE_BUCKET/$OFFSITE_PREFIX/$1" "$2" ;;
    aws) aws s3 cp --only-show-errors ${OFFSITE_ENDPOINT:+--endpoint-url "$OFFSITE_ENDPOINT"} "s3://$OFFSITE_BUCKET/$OFFSITE_PREFIX/$1" "$2" ;;
  esac
}
remote_ls() {
  case "$OFFSITE_TOOL" in
    rclone) rclone lsf "vsw:$OFFSITE_BUCKET/$OFFSITE_PREFIX/" 2>/dev/null ;;
    aws) aws s3 ls ${OFFSITE_ENDPOINT:+--endpoint-url "$OFFSITE_ENDPOINT"} "s3://$OFFSITE_BUCKET/$OFFSITE_PREFIX/" | awk '{print $4}' ;;
  esac
}
offsite_upload() { # backup dir
  [ "$OFFSITE" = s3 ] || die "OFFSITE is '$OFFSITE' (set OFFSITE=s3 + OFFSITE_BUCKET/ENDPOINT/CREDS_FILE)"
  command -v "$OFFSITE_TOOL" >/dev/null 2>&1 || die "$OFFSITE_TOOL is not installed (apt install rclone)"
  offsite_key; offsite_env
  local n t; n="$(basename "$1").tar.gz.enc"; [ "$OFFSITE_ENCRYPTION" = age ] && n="$(basename "$1").tar.gz.age"
  install -d -m 700 "$BACKUP_DIR"; t="$(mktemp "$BACKUP_DIR/.offsite-XXXX")"; chmod 600 "$t"
  log "Off-site copy $n -> $OFFSITE_BUCKET/$OFFSITE_PREFIX ($OFFSITE_ENCRYPTION)"
  tar -C "$(dirname "$1")" -cz "$(basename "$1")" | offsite_encrypt > "$t"
  (cd "$(dirname "$t")" && { sha256sum "$(basename "$t")" 2>/dev/null || shasum -a 256 "$(basename "$t")"; }) | awk -v n="$n" '{print $1"  "n}' > "$t.sha256"
  remote_put "$t" "$n" && remote_put "$t.sha256" "$n.sha256"; local rc=$?
  rm -f "$t" "$t.sha256"
  [ "$rc" = 0 ] || return 1
  if [ "$OFFSITE_TOOL" = rclone ]; then rclone delete --min-age "${OFFSITE_KEEP_DAYS}d" "vsw:$OFFSITE_BUCKET/$OFFSITE_PREFIX/" >/dev/null 2>&1 || warn "off-site prune failed"; fi
  stamp offsite "$n"; echo "off-site ok: $n"
}
cmd_offsite() { # backup [dir] | list | verify [name] | fetch <name> [dir]
  need_root; load_env 2>/dev/null || true
  local sub="${1:-}"; shift || true
  case "$sub" in
    backup) local d="${1:-$(newest_backup)}"; [ -d "$d" ] || die "no backup dir"; offsite_upload "$d" ;;
    list) offsite_env; remote_ls ;;
    verify|fetch)
      offsite_key; offsite_env
      local n="${1:-}"; [ -n "$n" ] || n="$(remote_ls | grep -E '\.tar\.gz\.(enc|age)$' | sort | tail -1)"
      [ -n "$n" ] || die "no off-site copies found"
      local t; t="$(mktemp -d)"; chmod 700 "$t"
      remote_get "$n" "$t/$n"; remote_get "$n.sha256" "$t/$n.sha256"
      (cd "$t" && { sha256sum -c --quiet "$n.sha256" 2>/dev/null || shasum -a 256 -c --quiet "$n.sha256"; }) || { rm -rf "$t"; die "checksum mismatch for $n"; }
      mkdir -p "$t/x"; offsite_decrypt < "$t/$n" | tar -C "$t/x" -xz || { rm -rf "$t"; die "cannot decrypt/unpack $n (wrong key?)"; }
      local d; d="$(find "$t/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
      verify_backup "$d"
      if [ "$sub" = fetch ]; then local to="${2:-$BACKUP_DIR/offsite}"; (umask 077; mkdir -p "$to"); mv "$d" "$to/"; echo "fetched to $to/$(basename "$d")"; fi
      rm -rf "$t"; stamp offsite-verify "$n"; echo "off-site verify ok: $n" ;;
    *) die "usage: offsite backup [dir] | list | verify [name] | fetch <name> [dir]" ;;
  esac
}

# ---- MySQL/MariaDB binlogs: retention (BINLOG_DAYS) + optional off-site shipping ---
cmd_binlog_ship() {
  need_root; need_stack; load_env
  local e cur f d
  for e in mysql mariadb; do
    on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || continue
    d="$BACKUP_DIR/binlogs/$e"; (umask 077; mkdir -p "$d")
    printf 'FLUSH BINARY LOGS;\n' | my_q "$e"
    cur="$(printf 'SHOW BINARY LOG STATUS;\n' | my_q "$e" 2>/dev/null | awk '{print $1; exit}')"
    [ -n "$cur" ] || cur="$(printf 'SHOW MASTER STATUS;\n' | my_q "$e" | awk '{print $1; exit}')"
    for f in $(printf 'SHOW BINARY LOGS;\n' | my_q "$e" | awk '{print $1}'); do
      [ "$f" = "$cur" ] && continue; [ -f "$d/$f.gz" ] && continue
      dc exec -T "$e" cat "/var/lib/mysql/$f" | gzip > "$d/$f.gz"; chmod 600 "$d/$f.gz"
      if [ "$OFFSITE" = s3 ]; then offsite_key; offsite_env; offsite_encrypt < "$d/$f.gz" > "$d/.$f.enc"; remote_put "$d/.$f.enc" "binlogs/$e/$f.gz.enc"; rm -f "$d/.$f.enc"; fi
      echo "shipped $e $f"
    done
    find "$d" -name '*.gz' -mtime +"$BINLOG_DAYS" -delete
  done
  stamp binlog-ship
}

# ---- PITR: pgBackRest inside the postgres container -----------------------------
pgbr() { dc exec -T -u postgres postgres pgbackrest --config=/etc/postgresql/vsw/pgbackrest.conf --stanza=main "$@"; }
pgbr_version_ok() {
  local v; v="$(dc exec -T postgres pgbackrest version 2>/dev/null | awk '{print $2}')"
  [ -n "$v" ] || { echo "pgbackrest missing"; return 1; }
  printf '%s\n%s\n' "$PGBACKREST_MIN_VERSION" "$v" | sort -V -C || { echo "pgbackrest $v < $PGBACKREST_MIN_VERSION"; return 1; }
  echo "pgbackrest $v"
}
cmd_pitr() { # setup | backup [full|diff|incr] | status | restore --target "YYYY-MM-DD HH:MM:SS+00" [--force-prod]
  need_root; need_stack; load_env
  pitr_on || die "PITR is off (set PITR=pgbackrest, then upgrade)"
  local sub="${1:-status}"; shift || true
  case "$sub" in
    setup) pgbr_version_ok || die "need pgBackRest >= $PGBACKREST_MIN_VERSION in the image (PGBACKREST_PKG)"
      pgbr stanza-create; pgbr check; pgbr --type=full backup; stamp pitr-backup full; echo "PITR ready" ;;
    backup) pgbr --type="${1:-diff}" backup && stamp pitr-backup "${1:-diff}" || { notify pitr fail "pgbackrest ${1:-diff} backup failed"; die "pgbackrest backup failed"; } ;;
    status) pgbr_version_ok || true; pgbr info ;;
    restore)
      local target="" force=0
      while [ $# -gt 0 ]; do case "$1" in --target) target="${2:-}"; shift ;; --force-prod) force=1 ;; esac; shift; done
      [ -n "$target" ] || die "usage: pitr restore --target 'YYYY-MM-DD HH:MM:SS+00' [--force-prod]"
      echo "Point-in-time restore of the WHOLE Postgres cluster to $target. Everything after it is lost."
      local pe=""; for e in $(local_envs); do env_protected "$e" && pe="$e"; done
      if [ -n "$pe" ]; then guard_destructive cluster "$pe" "$force"; else confirm RESTORE; cmd_backup; fi
      on "$ENABLE_PGBOUNCER" && dc stop pgbouncer
      dc stop postgres
      dc run --rm --no-deps -u postgres --entrypoint pgbackrest postgres --config=/etc/postgresql/vsw/pgbackrest.conf \
        --stanza=main --delta --type=time "--target=$target" --target-action=promote restore
      dc up -d --wait postgres; on "$ENABLE_PGBOUNCER" && dc up -d --wait pgbouncer
      echo "PITR restore done; run: verify, doctor, then pitr backup full" ;;
    *) die "usage: pitr setup|backup [full|diff|incr]|status|restore --target T" ;;
  esac
}

# ---- doctor: read-only checks of everything this script sets up ------------------
# PROBLEM = something is unsafe or broken (exit 1). warn = worth a look (exit 0).
# DOCTOR_CONTEXT=upgrade: stale backups/tests are warnings only (the upgrade just made one).
listen_addrs() { # $1 port -> space-separated listening addr:port, "" if none, "?" if no tool
  if command -v ss >/dev/null 2>&1; then { ss -Htln "sport = :$1" 2>/dev/null || true; } | awk '{print $4}' | tr '\n' ' '
  elif command -v lsof >/dev/null 2>&1; then { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR>1{print $9}' | sort -u | tr '\n' ' '
  else echo "?"; fi
}
# RAM each engine needs at minimum (MB), from docs/reference/sizing.md; the OS + Docker take 512
engine_ram_mb() { local t=512
  on "$ENABLE_POSTGRES" && t=$((t + 1024)); on "$ENABLE_PGBOUNCER" && t=$((t + 64))
  on "$ENABLE_MYSQL" && t=$((t + 1024)); on "$ENABLE_MARIADB" && t=$((t + 768)); on "$ENABLE_ADMINER" && t=$((t + 64))
  pitr_on && t=$((t + 128)); echo "$t"; }
size_for_mb() { # smallest DO basic size with at least this much RAM
  local need="$1"
  if [ "$need" -le 1024 ]; then echo s-1vcpu-1gb; elif [ "$need" -le 2048 ]; then echo s-1vcpu-2gb
  elif [ "$need" -le 4096 ]; then echo s-2vcpu-4gb; elif [ "$need" -le 8192 ]; then echo s-4vcpu-8gb; else echo s-8vcpu-16gb; fi
}
host_ram_mb() { awk '/^MemTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0; }
D_BAD=0 D_WARN=0
d_ok() { echo "  ok    $*"; }
d_warn() { echo "  warn  $*"; D_WARN=$((D_WARN + 1)); }
d_bad() { echo "  PROBLEM  $*"; D_BAD=$((D_BAD + 1)); }
d_stale() { if [ "${DOCTOR_CONTEXT:-}" = upgrade ]; then d_warn "$*"; else d_bad "$*"; fi; }
stack_up() { [ -f "$DB_DIR/docker-compose.yml" ] && (cd "$DB_DIR" && dc ps --status running --services 2>/dev/null | grep -qx "$1"); }

doctor_exposure() {
  log "Exposure: DB ports must listen on $PRIVATE_IP${EXTRA_BIND_IPS:+ and $EXTRA_BIND_IPS} only"
  local p l a x
  for p in $(enabled_ports); do
    l="$(listen_addrs "$p")"
    if [ "$l" = "?" ]; then d_warn "$p: unknown (no ss or lsof)"
    elif [ -z "$l" ]; then d_warn "$p: not listening"
    elif echo "$l" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):'; then d_bad "$p: PUBLIC ($l)"
    else
      x=""; for a in $l; do a="${a%:*}"; [ "$a" = "$PRIVATE_IP" ] || in_list "$a" "$(extra_binds)" || x="$x $a"; done
      if [ -n "$x" ]; then d_bad "$p: listens on unexpected address(es)$x ($l)"; else d_ok "$p: $l"; fi
    fi
  done
  for a in $(extra_binds); do ip_private "$a" || d_warn "$a is a public bind: Docker ports bypass ufw, so a DO cloud firewall must allow only the app servers (workbench do firewall-apply db ...)"; done
  echo "  (Docker-published ports bypass ufw; binding to the private IP keeps them off the internet.)"
  if on "$ENABLE_ADMINER"; then
    l="$(listen_addrs "$ADMINER_PORT")"
    if [ -n "$l" ] && [ "$l" != "?" ] && echo "$l" | grep -qvE '^(127\.0\.0\.1:[0-9]+[[:space:]]*)+$'; then d_bad "adminer $ADMINER_PORT not loopback-only ($l)"
    else d_ok "adminer: ${l:-not listening} (tunnel only)"; fi
  fi
}
doctor_network() { # region / VPC sanity: DO VPCs are per region (docs/cross-region.md)
  log "Network: region and VPC"
  ip_in_cidr "$PRIVATE_IP" "$VPC_CIDR" && d_ok "PRIVATE_IP $PRIVATE_IP is inside VPC_CIDR $VPC_CIDR" \
    || d_bad "PRIVATE_IP $PRIVATE_IP is outside VPC_CIDR $VPC_CIDR (ufw and pg_hba would refuse the app servers)"
  local region="" r wg=0 a
  command -v curl >/dev/null 2>&1 && region="$(curl -fsS --max-time 2 "$METADATA_URL/region" 2>/dev/null || true)"
  [[ "$region" =~ ^[a-z]{3}[0-9]$ ]] || region=""
  for a in $(extra_binds); do ip -4 -o addr show dev wg0 2>/dev/null | grep -q "inet $a/" && wg=1; done
  if [ -z "$region" ]; then d_warn "region: unknown (not a DigitalOcean droplet, or metadata unreachable)"; return 0; fi
  d_ok "this droplet is in $region"
  [ -n "$PEER_REGIONS" ] || { echo "  (set PEER_REGIONS to the app servers' regions to check them)"; return 0; }
  for r in ${PEER_REGIONS//,/ }; do
    if [ "$r" = "$region" ]; then d_ok "peer region $r: same region, the VPC works"
    elif [ "$wg" = 1 ]; then d_ok "peer region $r: different region, reached over WireGuard (wg0)"
    elif [ "$TLS_MODE" = require ] && [ "$ALLOW_PUBLIC_BIND" = 1 ]; then d_warn "peer region $r: different region over a public address with TLS; check the cloud firewall allowlist"
    else d_bad "peer region $r differs from $region: the app can't reach $PRIVATE_IP (VPCs are per region). Move the servers, or: workbench net wireguard setup (docs/cross-region.md)"; fi
  done
}
doctor_host() {
  log "Host"
  if command -v ufw >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    if ufw status verbose | grep -q 'Status: active'; then d_ok "ufw active"; else d_bad "ufw is not active"; fi
    ufw status verbose | grep -q 'deny (incoming)' && d_ok "ufw default deny incoming" || d_bad "ufw default incoming is not deny"
  else d_warn "ufw: unknown (needs root and ufw)"; fi
  if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then d_ok "unattended-upgrades enabled"
  else d_warn "unattended-upgrades not enabled (apt install unattended-upgrades)"; fi
  [ -f /var/run/reboot-required ] && d_warn "reboot required (server update --reboot-window)" || d_ok "no reboot pending"
  local use; use="$(df -P "$DB_DIR" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if [ -n "$use" ]; then if [ "$use" -ge 90 ]; then d_bad "disk $use% used on $DB_DIR"; elif [ "$use" -ge 80 ]; then d_warn "disk $use% used on $DB_DIR"; else d_ok "disk $use% used"; fi; fi
  local need have; need="$(engine_ram_mb)"; have="$(host_ram_mb)"
  if [ "$have" -gt 0 ] && [ "$have" -lt "$((need * 90 / 100))" ]; then
    d_warn "RAM ${have}MB < ${need}MB for the enabled engines. Resize: bin/workbench do resize <droplet> --size $(size_for_mb "$need")  (or disable an engine: engine disable mysql)"
  elif [ "$have" -gt 0 ]; then d_ok "RAM ${have}MB (engines need ~${need}MB)"; fi
  if [ -n "$(docker network ls --filter "name=^${DOCKER_NETWORK}\$" -q 2>/dev/null)" ]; then
    local sn; sn="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$DOCKER_NETWORK" 2>/dev/null)"
    [ "$sn" = "$DOCKER_SUBNET" ] && d_ok "docker network $DOCKER_NETWORK $sn" || d_bad "docker network $DOCKER_NETWORK is $sn, config says $DOCKER_SUBNET"
  fi
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '(^| |,)0\.0\.0\.0:' | grep -v '^vsw-rt-' | while read -r l; do echo "  warn  another container publishes on all interfaces: $l"; done || true
  return 0
}
doctor_postgres() {
  on "$ENABLE_POSTGRES" && stack_up postgres || return 0
  log "PostgreSQL"
  local x
  x="$(pg_val postgres "select string_agg(rolname, ' ') from pg_roles where rolsuper")"
  [ "$x" = "$PG_ADMIN_USER" ] && d_ok "only superuser: $x" || { pg_legacy && d_bad "app login $PG_USER is a superuser (run: upgrade, it splits the roles)" || d_bad "superusers: $x (expected only $PG_ADMIN_USER)"; }
  x="$(pg_val postgres "select (case when rolsuper then 's' else '' end)||(case when rolcreaterole then 'r' else '' end)||(case when rolreplication then 'p' else '' end)||(case when rolbypassrls then 'b' else '' end)||(case when rolcreatedb then 'd' else '' end) from pg_roles where rolname='$PG_USER'")"
  case "$x" in "") d_ok "$PG_USER: no special attributes" ;; d) [ "$PG_APP_CREATEDB" = 1 ] && d_ok "$PG_USER: CREATEDB (tenants on)" || d_bad "$PG_USER has CREATEDB but PG_APP_CREATEDB=0" ;;
    *) [ "$x" = s ] || [ "${x#s}" != "$x" ] || d_bad "$PG_USER has attributes '$x' (s=super r=createrole p=replication b=bypassrls)" ;; esac
  x="$(pg_val postgres "select string_agg(rolname, ' ') from pg_roles where rolname not like 'pg\_%' and rolname <> '$PG_ADMIN_USER' and (rolcreaterole or rolreplication or rolbypassrls or rolsuper)")"
  [ -z "$x" ] && d_ok "no other role has superuser/createrole/replication/bypassrls" || d_bad "roles with admin attributes: $x"
  x="$(pg_val postgres "select string_agg(datname, ' ') from pg_database where not datistemplate and datname not in ('postgres') and has_database_privilege('public', datname, 'CONNECT')")"
  [ -z "$x" ] && d_ok "PUBLIC cannot connect to app databases" || d_warn "PUBLIC may connect to: $x (create-db and converge revoke it)"
  x="$(pg_val postgres "select string_agg(datname, ' ') from pg_database d where pg_get_userbyid(datdba) = '$PG_USER' and datname = '$PG_DB'")"
  [ -z "$x" ] && d_ok "$PG_DB is owned by an admin (the app cannot drop it)" || d_bad "$PG_DB is owned by $PG_USER (it could drop it)"
  x="$(pg_val postgres "select count(*) from pg_hba_file_rules where (address = '0.0.0.0' and netmask = '0.0.0.0') or (type <> 'local' and auth_method in ('trust','password','md5'))")"
  [ "$x" = 0 ] && d_ok "pg_hba: no open or trust network rules" || d_bad "pg_hba has $x rules that are open to all or use trust/md5"
  x="$(pg_val postgres "select count(*) from pg_hba_file_rules where error is not null")"; [ "$x" = 0 ] || d_bad "pg_hba has $x invalid lines"
  for x in log_connections log_disconnections; do [ "$(pg_val postgres "show $x")" != off ] && d_ok "$x on" || d_warn "$x is off"; done
  x="$(pg_val postgres "show log_min_duration_statement")"; [ "$x" != -1 ] && d_ok "slow query log at $x" || d_warn "slow query log off"
  if tls_on; then
    [ "$(pg_val postgres "show ssl")" = on ] && d_ok "TLS on" || d_bad "TLS_MODE=require but ssl is off"
    x="$DB_DIR/tls/server.crt"; if openssl x509 -checkend $((21 * 86400)) -noout -in "$x" >/dev/null 2>&1; then d_ok "TLS certificate valid > 21 days"; else d_bad "TLS certificate expires within 21 days (upgrade renews it)"; fi
  fi
  for x in $PG_EXTENSIONS; do
    [ "$(pg_val template1 "select count(*) from pg_extension where extname='$x'")" = 1 ] || d_warn "extension $x missing in template1"
  done
  x="$(pg_val postgres "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgbouncer' and proname='get_auth' and prosecdef")"
  on "$ENABLE_PGBOUNCER" && { [ "$x" = 1 ] && d_ok "pgbouncer.get_auth present (SECURITY DEFINER)" || d_bad "pgbouncer.get_auth missing (run upgrade)"; }
  if [ -n "$(docker image ls -q "$PG_IMAGE_LEGACY" 2>/dev/null)" ] && [ "$PG_IMAGE_LEGACY" != "$PG_IMAGE" ]; then d_warn "old image tag $PG_IMAGE_LEGACY still present (upgrade retires it)"; fi
  doctor_pg_users
}
doctor_pg_users() { # every login vs the privilege model (docs/reference/privileges.md)
  local x
  x="$(pg_val postgres "select string_agg(r.rolname || '->' || d.datname, ' ') from pg_roles r cross join pg_database d where r.rolcanlogin and not r.rolsuper and not d.datistemplate and d.datname <> 'postgres' and d.datdba = r.oid and r.rolname <> '$PG_USER' and d.datname not like '%\_t\_%' and d.datname not like '%\_\_trash\_%'")"
  [ -z "$x" ] && d_ok "no login owns a database it could drop" || d_warn "logins owning databases (they can DROP them): $x"
  if [ -n "$APP" ]; then
    local e db a; for e in $(local_envs); do
      db="$(env_db "$e")"; a="$(env_role "$e" app)"
      [ "$(pg_val postgres "select count(*) from pg_database where datname='$db'")" = 1 ] && d_ok "env $e: $db exists" || { d_bad "env $e: $db missing (env-apply)"; continue; }
      x="$(pg_val postgres "select string_agg(datname, ' ') from pg_database where pg_get_userbyid(datdba) = '$a' and datname !~ '^${db}_t_[a-z0-9_]+\$'")"
      [ -z "$x" ] && d_ok "env $e: tenant DBs follow ${db}_t_<id>" || d_bad "env $e: $a owns databases outside its prefix: $x"
      x="$(pg_val postgres "select rolcreatedb from pg_roles where rolname='$a'")"
      if env_tenants "$e"; then [ "$x" = t ] || d_warn "env $e: tenants on but $a has no CREATEDB"; else [ "$x" = f ] || d_bad "env $e: $a has CREATEDB but tenants are off"; fi
      x="$(pg_val "$db" "select count(*) from information_schema.role_table_grants where grantee='$(env_role "$e" ro)' and privilege_type <> 'SELECT'")"
      [ "$x" = 0 ] && d_ok "env $e: read-only role is SELECT only" || d_bad "env $e: read-only role has write grants"
    done
    x="$(pg_val postgres "select string_agg(datname, ' ') from pg_database where datname like '${APP}\_%' and datname !~ '^${APP}_($(echo "$ENVS" | tr ' ' '|'))(_t_[a-z0-9_]+|__trash_[0-9]+)?\$'")"
    [ -z "$x" ] && d_ok "every ${APP}_* database matches the naming contract" || d_warn "databases outside the naming contract: $x"
  fi
}
doctor_mysql() { # engine
  local e="$1" x; on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" && stack_up "$e" || return 0
  log "$e"
  x="$(printf "select count(*) from mysql.user where user='root' and host='%%';\n" | my_q "$e")"
  [ "$x" = 0 ] && d_ok "no root@'%'" || d_bad "root@'%' exists (upgrade removes it)"
  x="$(printf "select @@local_infile;\n" | my_q "$e")"; [ "$x" = 0 ] && d_ok "local_infile=0" || d_bad "local_infile is on"
  if [ "$e" = mariadb ]; then x="$(printf "select @@secure_file_priv;\n" | my_q "$e")"; [ -n "$x" ] && [ "$x" != NULL ] && d_ok "secure_file_priv=$x" || d_bad "secure_file_priv is empty (any directory)"; fi
  x="$(printf "select group_concat(concat(user,'@',host)) from mysql.user where user not in ('root','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','healthcheck','') and (Super_priv='Y' or File_priv='Y' or Process_priv='Y' or Grant_priv='Y' or Select_priv='Y' or Insert_priv='Y' or Drop_priv='Y' or Create_user_priv='Y' or Shutdown_priv='Y');\n" | my_q "$e")"
  [ -z "$x" ] || [ "$x" = NULL ] && d_ok "no app user has global privileges or GRANT OPTION" || d_bad "users with global privileges: $x"
  x="$(printf "select group_concat(distinct concat(user,'@',host)) from mysql.db where Grant_priv='Y' and user not in ('root','mysql.sys','mariadb.sys');\n" | my_q "$e")"
  [ -z "$x" ] || [ "$x" = NULL ] && d_ok "no database-level GRANT OPTION" || d_bad "database-level GRANT OPTION: $x"
  x="$(my_q "$e" <<'SQL'
select group_concat(distinct db) from mysql.db where db regexp '(^|[^\\\\])_' and user not in ('mysql.sys','mariadb.sys','mysql.session');
SQL
)"
  [ -z "$x" ] || [ "$x" = NULL ] && d_ok "grants escape _ in database names" || d_warn "grants with unescaped _ (wildcard, matches more databases): $x"
  if tls_on; then [ "$(printf 'select @@require_secure_transport;\n' | my_q "$e")" = 1 ] && d_ok "TLS required" || d_bad "TLS_MODE=require but require_secure_transport is off"; fi
}
doctor_backups() {
  log "Backups and recovery"
  local b age
  b="$(newest_backup)"
  if [ -z "$b" ]; then d_stale "no backup yet in $BACKUP_DIR (backup; cron-install)"
  else age=$(( ($(date +%s) - $(stat -c %Y "$b" 2>/dev/null || stat -f %m "$b")) / 3600 ))
    [ "$age" -le "$BACKUP_MAX_AGE_H" ] && d_ok "newest backup $(basename "$b") (${age}h)" || d_stale "newest backup is ${age}h old (limit ${BACKUP_MAX_AGE_H}h)"
  fi
  [ -f "$CRON_FILE" ] && d_ok "cron: $CRON_FILE" || d_warn "no cron jobs (cron-install)"
  if [ "$OFFSITE" != none ]; then
    age="$(stamp_age_h offsite)"; [ -n "$age" ] && [ "$age" -le "$BACKUP_MAX_AGE_H" ] && d_ok "off-site copy ${age}h old" || d_stale "off-site copy missing or older than ${BACKUP_MAX_AGE_H}h"
    [ -f "$OFFSITE_KEY_FILE" ] && d_ok "off-site key present (keep a copy off this server)" || d_warn "no $OFFSITE_KEY_FILE yet"
  else d_warn "no off-site copies (OFFSITE=none): a lost droplet loses its backups too"; fi
  age="$(stamp_age_h restore-test)"
  [ -n "$age" ] && [ "$age" -le "$((RESTORE_TEST_MAX_AGE_D * 24))" ] && d_ok "restore test ${age}h ago" || d_warn "no restore test in ${RESTORE_TEST_MAX_AGE_D} days (restore-test)"
  if pitr_on && stack_up postgres; then
    if pgbr info >/dev/null 2>&1; then
      x="$(pgbr info --output=json 2>/dev/null | grep -o '"status":{"code":[0-9]*' | head -1 | grep -o '[0-9]*$')"
      [ "${x:-1}" = 0 ] && d_ok "pgBackRest stanza ok" || d_bad "pgBackRest stanza not ok (pitr setup)"
      [ "$(pg_val postgres "select coalesce(extract(epoch from now() - last_archived_time)::int, 999999) < 3600 from pg_stat_archiver")" = t ] && d_ok "WAL archiving within the last hour" || d_stale "WAL archiving is behind or failing (pg_stat_archiver)"
      [ "$(pg_val postgres "select failed_count > 0 and coalesce(last_failed_time > last_archived_time, false) from pg_stat_archiver")" = t ] && d_bad "last WAL archive attempt failed"
    else d_bad "PITR=pgbackrest but pgbackrest info fails (pitr setup)"; fi
  fi
  return 0
}
cmd_doctor() { # [--alert]
  local alert=0; [ "${1:-}" = --alert ] && alert=1
  D_BAD=0 D_WARN=0
  [ -f "$DB_DIR/.env" ] && { cd "$DB_DIR"; load_env; }
  # a check that errors out must not stop the others: run each section on its own
  local s; for s in doctor_exposure doctor_network doctor_host doctor_postgres "doctor_mysql mysql" "doctor_mysql mariadb" doctor_backups; do
    $s || d_bad "check '$s' could not finish (exit $?)"
  done
  echo
  if [ "$D_BAD" = 0 ]; then echo "doctor: no problems ($D_WARN warnings)"; stamp doctor ok; [ "$alert" = 0 ] || notify doctor ok "no problems"
  else echo "doctor: $D_BAD problems, $D_WARN warnings (see PROBLEM lines)"; stamp doctor "fail $D_BAD"
    [ "$alert" = 0 ] || notify doctor fail "$D_BAD problems: run doctor on $(hostname)"; return 1; fi
}

# ---- engines: enable / disable without losing data ------------------------------
set_conf_key() { # key value: edit the manager config file in place (600, backup kept)
  local f="$DBM_CONFIG"; [ -f "$f" ] || die "no config file $f (init > $f first)"
  cp -p "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
  local t; t="$(mktemp "$f.XXXX")"; chmod 600 "$t"
  grep -v "^$1=" "$f" > "$t" || true; printf '%s=%s\n' "$1" "$2" >> "$t"; mv "$t" "$f"
}
cmd_engine() { # enable|disable <engine> [--delete-volume] [--dry-run]
  need_root; need_stack; load_env
  local act="${1:-}" e="${2:-}" del=0 dry=0 a v; shift 2 || true
  for a in "$@"; do case "$a" in --delete-volume) del=1 ;; --dry-run) dry=1 ;; *) die "unknown option $a" ;; esac; done
  case "$e" in postgres) v=ENABLE_POSTGRES ;; pgbouncer) v=ENABLE_PGBOUNCER ;; mysql) v=ENABLE_MYSQL ;; mariadb) v=ENABLE_MARIADB ;; adminer) v=ENABLE_ADMINER ;;
    *) die "usage: engine enable|disable postgres|pgbouncer|mysql|mariadb|adminer [--delete-volume] [--dry-run]" ;; esac
  case "$act" in
    disable)
      on "${!v}" || { echo "$e is already disabled"; return 0; }
      [ "$e" = postgres ] && on "$ENABLE_PGBOUNCER" && die "disable pgbouncer first"
      echo "plan: back up, set $v=0 in $DBM_CONFIG, remove the $e container, KEEP its volume$([ "$del" = 1 ] && echo ', then delete the volume after a separate typed confirmation'), run doctor"
      [ "$dry" = 1 ] && return 0
      confirm DISABLE
      cmd_backup
      set_conf_key "$v" 0; printf -v "$v" 0
      write_files; dc up -d --wait --remove-orphans; firewall
      if [ "$del" = 1 ]; then
        local vol; vol="$(basename "$DB_DIR")_$( case "$e" in postgres) echo pg_data ;; mysql) echo mysql_data ;; mariadb) echo mariadb_data ;; *) echo none ;; esac )"
        if [ "$vol" != "$(basename "$DB_DIR")_none" ] && docker volume inspect "$vol" >/dev/null 2>&1; then
          echo "The data volume $vol will be DELETED. The backup $(newest_backup) is the only copy afterwards."
          if [ "${WORKBENCH_CONFIRM:-}" = "DELETE $vol" ]; then :; elif [ "$INTERACTIVE" = 1 ]; then ask_word "DELETE-$vol"; else die "type DELETE-$vol interactively (or WORKBENCH_CONFIRM='DELETE $vol')"; fi
          docker volume rm "$vol" && echo "deleted volume $vol"
        fi
      else echo "volume kept (engine enable $e brings the data back)"; fi ;;
    enable)
      on "${!v}" && { echo "$e is already enabled"; return 0; }
      [ "$e" = pgbouncer ] && ! on "$ENABLE_POSTGRES" && die "enable postgres first"
      local need have; printf -v "$v" 1; need="$(engine_ram_mb)"; have="$(host_ram_mb)"; printf -v "$v" 0
      [ "$have" = 0 ] || [ "$have" -ge "$((need * 90 / 100))" ] || warn "RAM ${have}MB < ${need}MB needed with $e on; consider: bin/workbench do resize <droplet> --size $(size_for_mb "$need")"
      echo "plan: set $v=1 in $DBM_CONFIG, start $e (existing volume reused), converge, run doctor"
      [ "$dry" = 1 ] && return 0
      confirm ENABLE
      set_conf_key "$v" 1; printf -v "$v" 1
      ensure_env_keys; write_files; start_stack; firewall ;;
    *) die "usage: engine enable|disable <engine>" ;;
  esac
  ( set -e; cmd_doctor ) || warn "doctor reported problems (see above)"
}

cmd_init() { # [file]: starter config for this host, no secrets
  local cidr ip net out="${1:-/dev/stdout}"
  cidr="$(ip -4 -o addr show "$PRIVATE_IFACE" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
  ip="${cidr%/*}"; net="$VPC_CIDR"
  if [ -n "$cidr" ]; then
    local bits="${cidr#*/}" a b c d n m
    IFS=. read -r a b c d <<<"$ip"; n=$(( (a<<24)|(b<<16)|(c<<8)|d )); m=$(( (0xFFFFFFFF << (32-bits)) & 0xFFFFFFFF ))
    n=$((n & m)); net="$((n>>24&255)).$((n>>16&255)).$((n>>8&255)).$((n&255))/$bits"
  fi
  cat > "$out" <<EOF
# $TOOL_NAME config for $(hostname) - written by init on $(date +%F). No secrets.
# Install: sudo install -m 600 THIS_FILE $DBM_CONFIG
EXPECTED_PRIVATE_IP=${ip}
PRIVATE_IP=${ip}
VPC_CIDR=${net}
DB_DIR=$DB_DIR
KEEP=$KEEP
# Engines (1 = on, 0 = off)
ENABLE_POSTGRES=$ENABLE_POSTGRES
ENABLE_PGBOUNCER=$ENABLE_PGBOUNCER
ENABLE_MYSQL=$ENABLE_MYSQL
ENABLE_MARIADB=$ENABLE_MARIADB
# Optional Adminer web UI on 127.0.0.1 only (SSH tunnel)
ENABLE_ADMINER=$ENABLE_ADMINER
# Postgres: app login + main database; $PG_ADMIN_USER is the only superuser
PG_USER=$PG_USER
PG_DB=$PG_DB
PG_APP_CREATEDB=$PG_APP_CREATEDB
#PG_EXTENSIONS=$PG_EXTENSIONS
# TLS for client connections (self-signed, made on this server): off | require
TLS_MODE=$TLS_MODE
# Backups: GFS retention, off-site copies (encrypted), PITR - see docs/backups-and-recovery.md
#RETENTION="daily=7 weekly=4 monthly=3"
#OFFSITE=s3
#OFFSITE_ENDPOINT=https://ams3.digitaloceanspaces.com
#OFFSITE_BUCKET=my-backups
#PITR=pgbackrest
# Alerts (any of): ALERT_EMAIL, ALERT_WEBHOOK, HEALTHCHECK_URL, ALERT_COMMAND
#HEALTHCHECK_URL=https://hc-ping.com/<uuid>
# Environments: run env-init to add the APP/ENVS block
EOF
  [ "$out" = /dev/stdout ] || echo "wrote $out"
  [ -n "$ip" ] || warn "$PRIVATE_IFACE has no IPv4 here; fill in PRIVATE_IP/VPC_CIDR by hand"
}

summary() {
  log "Done"
  on "$ENABLE_POSTGRES"  && echo "PostgreSQL ($PG_IMAGE)  : $PRIVATE_IP:$PG_PORT  (app $PG_USER, db $PG_DB; admin $PG_ADMIN_USER)"
  on "$ENABLE_PGBOUNCER" && echo "PgBouncer ($PGBOUNCER_POOL_MODE mode) : $PRIVATE_IP:$PGBOUNCER_PORT"
  on "$ENABLE_MYSQL"     && echo "MySQL ($MYSQL_IMAGE)     : $PRIVATE_IP:$MYSQL_PORT  (root: localhost/docker network only)"
  on "$ENABLE_MARIADB"   && echo "MariaDB ($MARIADB_IMAGE) : $PRIVATE_IP:$MARIADB_PORT  (root: localhost/docker network only)"
  on "$ENABLE_ADMINER"   && echo "Adminer ($ADMINER_IMAGE) : 127.0.0.1:$ADMINER_PORT only - tunnel: ssh -N -L 8081:127.0.0.1:$ADMINER_PORT <user>@<db-public-ip>"
  echo "Admin and root passwords are in $DB_DIR/.env (chmod 600) - not printed."
  echo
  cmd_env
  echo
  echo "Then redeploy the web app (Laravel caches config at deploy time)."
  echo "Next: cron-install (backups + doctor --alert + restore tests), doctor"
}

cmd_install() {
  need_root; banner install; validate_config; ensure_docker
  mkdir -p "$DB_DIR"
  if [ -f "$DB_DIR/.env" ]; then echo "keeping existing $DB_DIR/.env"; ensure_env_keys; else new_env; fi
  load_env; write_files; start_stack; firewall; cmd_verify; summary
}

cmd_reset() {
  need_root; banner reset
  echo "This will DELETE all PostgreSQL, MySQL and MariaDB data in $DB_DIR"
  echo "(containers, volumes, image $PG_IMAGE) and create NEW passwords. Backups in $BACKUP_DIR are kept."
  if [ -n "$APP" ]; then local e; for e in $(local_envs); do env_protected "$e" && guard_destructive server "$e" "${RESET_FORCE_PROD:-0}" && break; done; fi
  confirm RESET
  ensure_docker
  log "Tearing down old stack"
  mkdir -p "$DB_DIR"; cd "$DB_DIR"
  if [ -f docker-compose.yml ]; then
    [ -f stack.env ] || write_stack_env
    dc down -v --remove-orphans || warn "compose down reported errors"
  fi
  local proj v; proj="$(basename "$DB_DIR")"
  for v in pg_data pg_pitr mysql_data mariadb_data; do docker volume rm -f "${proj}_${v}" >/dev/null 2>&1 || true; done
  docker image rm -f "$PG_IMAGE" >/dev/null 2>&1 || true
  if [ -f .env ]; then
    local b; b="/root/db-env-backup-$(date +%Y%m%d-%H%M%S)"
    (umask 077; cp .env "$b"); chmod 600 "$b"; echo "old .env backed up to $b"
  fi
  rm -rf "${DB_DIR:?}/postgres" "${DB_DIR:?}/pgbouncer" "${DB_DIR:?}/docker-compose.yml" "${DB_DIR:?}/stack.env" "${DB_DIR:?}/.env"
  new_env; load_env; write_files; start_stack --no-cache; firewall; cmd_verify; summary
}

cmd_uninstall() {
  need_root
  local purge=0; [ "${1:-}" = "--purge" ] && purge=1
  banner "uninstall$([ $purge = 1 ] && echo ' --purge')"
  if [ "$purge" = 1 ]; then
    echo "This DELETES all data, backups in $BACKUP_DIR, the image and $DB_DIR."
    if [ -n "$APP" ]; then local e; for e in $(local_envs); do env_protected "$e" && guard_destructive server "$e" "${PURGE_FORCE_PROD:-0}" && break; done; fi
    confirm PURGE
  fi
  if [ -f "$DB_DIR/docker-compose.yml" ]; then
    cd "$DB_DIR"
    if [ "$purge" = 1 ]; then dc down -v --remove-orphans; else dc down --remove-orphans; fi
  fi
  if [ "$purge" = 1 ]; then
    docker image rm -f "$PG_IMAGE" >/dev/null 2>&1 || true
    rm -f "$CRON_FILE" "$LOGROTATE_FILE"; cd /; rm -rf "${DB_DIR:?}"
    echo "purged (ufw rules left in place; remove with: ufw status numbered / ufw delete N)"
    [ -d "$ENV_SECRETS_DIR" ] && echo "environment secrets kept in $ENV_SECRETS_DIR (delete by hand when no longer needed)"
  else
    echo "stopped; data volumes and $DB_DIR kept (start again with: install)"
  fi
}

# ---- main -------------------------------------------------------------------
ARGS=()
for a in "$@"; do
  if [ -n "${skip_next:-}" ]; then skip_next=; continue; fi
  case "$a" in
    -y|--yes) FORCE=1 ;;
    --non-interactive) NONINTERACTIVE=1 ;;
    --config) skip_next=1 ;;
    --version) echo "$TOOL_NAME $VERSION"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD="${1:-help}"; shift || true
[ "${DBM_SOURCE_ONLY:-0}" = 1 ] && return 0 2>/dev/null   # tests: load functions only
if is_interactive; then INTERACTIVE=1; fi
detect_ip
case "$CMD" in help|-h|--help|init|env-init|env-sql|env-list|gfs-keep) ;; *) check_engines; guard_host; need_ip ;; esac
case "$CMD" in help|-h|--help|init|env-init) ;; *) validate_envs ;; esac
case "$CMD" in # mutating commands: one at a time
  upgrade|apply|install|reset|restore|backup|uninstall|create-db|create-user|grant|drop-db|drop-user|rotate-password|\
  env-apply|role-split|purge-trash|engine|offsite|binlog-ship|pitr|restore-test)
    need_root; take_lock ;;
esac
case "$CMD" in
  upgrade|apply) cmd_upgrade "$@" ;;
  install)      cmd_install ;;
  reset)        cmd_reset ;;
  status)       cmd_status ;;
  verify)       cmd_verify ;;
  env)          cmd_env "$@" ;;
  init)         cmd_init "$@" ;;
  create-db)    cmd_create_db "$@" ;;
  create-user)  cmd_create_user "$@" ;;
  grant)        cmd_grant "$@" ;;
  drop-db)      cmd_drop_db "$@" ;;
  drop-user)    cmd_drop_user "$@" ;;
  rotate-password) cmd_rotate_password "$@" ;;
  list-dbs)     cmd_list_dbs "$@" ;;
  list-users)   cmd_list_users "$@" ;;
  role-split)   cmd_role_split "$@" ;;
  env-init)     cmd_env_init "$@" ;;
  env-apply)    cmd_env_apply ;;
  env-list)     cmd_env_list ;;
  env-sql)      cmd_env_sql "$@" ;;
  env-creds)    cmd_env_creds "$@" ;;
  purge-trash)  cmd_purge_trash "$@" ;;
  doctor)       cmd_doctor "$@" ;;
  backup)       cmd_backup "$@" ;;
  restore)      cmd_restore "$@" ;;
  restore-test) cmd_restore_test "$@" ;;
  offsite)      cmd_offsite "$@" ;;
  binlog-ship)  cmd_binlog_ship ;;
  pitr)         cmd_pitr "$@" ;;
  engine)       cmd_engine "$@" ;;
  gfs-keep)     gfs_keep "$*" ;;
  cron-install) cmd_cron_install ;;
  cron-remove)  cmd_cron_remove ;;
  logs)         cmd_logs "$@" ;;
  uninstall)    cmd_uninstall "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $CMD" ;;
esac
