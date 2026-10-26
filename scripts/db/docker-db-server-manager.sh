#!/usr/bin/env bash
# =============================================================================
#  Docker DB Server Setup Manager            (docker-db-server-manager.sh)
# =============================================================================
#  PURPOSE
#    Builds, resets, checks, backs up and restores the Docker database stack on
#    a dedicated DB droplet (DigitalOcean, Ubuntu): PostgreSQL 18 + PostGIS 3.6 +
#    pgvector, PgBouncer 1.26.1 (session mode), MySQL 9.7 and MariaDB 13.
#    Every port is bound to the droplet's PRIVATE IP only.
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
#    install            first-time setup; keeps an existing .env and data
#    reset              DESTROY everything and start over with new passwords
#    status             containers, health, ports
#    verify             run all connection / extension checks
#    env                print the lines for the web server's Laravel .env
#    backup             dump all three engines to backups/<timestamp>/
#    restore <dir> [postgres|mysql|mariadb|all]   load a backup (overwrites)
#    cron-install       daily backup at 03:15 via /etc/cron.d
#    cron-remove        remove that cron job
#    logs [service]     follow container logs
#    uninstall [--purge]  stop stack; --purge also deletes data, image and $DB_DIR
#    help               detailed help with examples
#
#  CONFIGURATION
#    Settings come from (highest wins): environment variables, then the config
#    file (--config FILE, DBM_CONFIG, or /etc/docker-db-server-manager.conf),
#    then the defaults below. See config/db-server.env.example.
#
#  ENVIRONMENT OVERRIDES (most common)
#    PRIVATE_IP   bind address (default: eth1 IPv4; required if eth1 is missing)
#    EXPECTED_PRIVATE_IP  abort unless this IP is on the host (wrong-server guard)
#    VPC_CIDR     ufw source range (default 10.0.0.0/8 - set your VPC range)
#    PG_USER PG_DB PG_IMAGE PG_BASE_IMAGE PGVECTOR_PKG PGBOUNCER_IMAGE MYSQL_IMAGE
#    MARIADB_IMAGE PG_PORT PGBOUNCER_PORT MYSQL_PORT MARIADB_PORT WEB_ENV CRON_TIME
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
# shellcheck disable=SC1091,SC2016
set -euo pipefail
trap 'echo "!! ERROR: line $LINENO: \"$BASH_COMMAND\" failed" >&2' ERR

TOOL_NAME="Docker DB Server Setup Manager"
VERSION="1.0.0"

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
PG_IMAGE="${PG_IMAGE:-local/postgres:18-postgis-pgvector}"
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
PRIVATE_IFACE="${PRIVATE_IFACE:-eth1}"
CRON_TIME="${CRON_TIME:-15 3 * * *}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/docker-db-server-backup}"
CRON_LOG="${CRON_LOG:-/var/log/docker-db-server-backup.log}"
WEB_ENV="${WEB_ENV:-/home/ploi/<site>-shared/.env}"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!! WARNING: %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }
banner() { printf '%s\n' "=== $TOOL_NAME :: $1 ===" "    dir=$DB_DIR  ip=$PRIVATE_IP  vpc=$VPC_CIDR"; }

usage() {
cat <<EOF
$TOOL_NAME

Usage: $(basename "$0") <command> [args] [--yes]

Commands:
  install
      First-time setup. Installs Docker if missing, writes files, keeps an
      existing .env (and its passwords) and existing data, starts and verifies.
        sudo ./docker-db-server-manager.sh install

  reset   (DESTRUCTIVE)
      Deletes containers, volumes, the built image and generated files, backs
      up the old .env to /root, generates NEW passwords, rebuilds from scratch.
        sudo ./docker-db-server-manager.sh reset            # type RESET
        sudo ./docker-db-server-manager.sh reset --yes      # no prompt
        sudo PRIVATE_IP=10.0.0.5 FORCE=1 ./docker-db-server-manager.sh reset

  status
      Shows containers, health and bound ports.
        sudo ./docker-db-server-manager.sh status

  verify
      pg_isready, extension lists ($PG_DB + template1), login through
      PgBouncer ($PGBOUNCER_PORT), direct login ($PG_PORT), MySQL and MariaDB pings.
        sudo ./docker-db-server-manager.sh verify

  env
      Prints DB_* lines to paste into $WEB_ENV on the web server.
        sudo ./docker-db-server-manager.sh env

  backup
      Dumps PostgreSQL (pg_dumpall), MySQL and MariaDB (user DBs, not system) into
      \$BACKUP_DIR/<timestamp>/ as gzip; keeps the newest \$KEEP (default 7).
        sudo ./docker-db-server-manager.sh backup
        sudo KEEP=14 BACKUP_DIR=/mnt/vol/db ./docker-db-server-manager.sh backup

  restore <backup-dir> [postgres|mysql|mariadb|all]   (DESTRUCTIVE)
      Loads a backup over the current data (default: all). Type RESTORE.
        sudo ./docker-db-server-manager.sh restore $BACKUP_DIR/20261025-031500
        sudo ./docker-db-server-manager.sh restore /opt/db/backups/20261025-031500 postgres --yes

  cron-install | cron-remove
      Adds/removes a daily backup job ($CRON_TIME) in $CRON_FILE
      (log: $CRON_LOG).
        sudo ./docker-db-server-manager.sh cron-install

  logs [postgres|pgbouncer|mysql|mariadb]
      Follows container logs (Ctrl-C to stop).
        sudo ./docker-db-server-manager.sh logs pgbouncer

  uninstall [--purge]
      Stops and removes containers. --purge (DESTRUCTIVE, type PURGE) also
      removes volumes, the built image, the cron job and $DB_DIR (backups too).
        sudo ./docker-db-server-manager.sh uninstall
        sudo ./docker-db-server-manager.sh uninstall --purge

  help
      This text.

Options: --yes|-y (skip confirmation), --config FILE, --version
Environment: PRIVATE_IP, EXPECTED_PRIVATE_IP, VPC_CIDR, DB_DIR, BACKUP_DIR, KEEP, FORCE=1,
             PG_USER, PG_DB, *_IMAGE, *_PORT, CRON_TIME, WEB_ENV (see config/db-server.env.example)
Ports (private IP only): $PG_PORT Postgres, $PGBOUNCER_PORT PgBouncer, $MYSQL_PORT MySQL, $MARIADB_PORT MariaDB
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
dc() { docker compose --env-file .env --env-file stack.env "$@"; }
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
}

write_stack_env() { # non-secret compose settings; safe to rewrite at any time
  (cd "$DB_DIR" && cat > stack.env <<EOF
# non-secret settings, rewritten by $TOOL_NAME on every install/reset
PG_USER=$PG_USER
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
EOF
  )
}

write_files() {
  log "Writing files in $DB_DIR"
  cd "$DB_DIR"
  mkdir -p postgres/init
cat > postgres/Dockerfile <<'EOF'
# postgis/postgis is amd64-only (fine for DO droplets)
ARG PG_BASE_IMAGE
FROM ${PG_BASE_IMAGE}
ARG PGVECTOR_PKG
RUN sed -i 's|http://apt.postgresql.org|https://apt.postgresql.org|g' /etc/apt/sources.list.d/*.list \
 && apt-get -o Acquire::Retries=5 update \
 && apt-get -o Acquire::Retries=5 install -y --no-install-recommends ${PGVECTOR_PKG} \
 && rm -rf /var/lib/apt/lists/*
EOF

cat > postgres/init/10-extensions.sql <<EOF
-- runs once, on an empty data dir. template1 => every new (tenant) DB gets these.
\\set ON_ERROR_STOP on
\\c template1
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
\\c $PG_DB
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOF

write_stack_env


cat > docker-compose.yml <<'EOF'
services:
  postgres:
    build:
      context: ./postgres
      args:
        PG_BASE_IMAGE: ${PG_BASE_IMAGE}
        PGVECTOR_PKG: ${PGVECTOR_PKG}
    image: ${PG_IMAGE}
    restart: unless-stopped
    command: ["postgres", "-c", "shared_preload_libraries=pg_stat_statements", "-c", "max_connections=${PG_MAX_CONNECTIONS}"]
    environment:
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASSWORD}
      POSTGRES_DB: ${PG_DB}
    ports: ["${PRIVATE_IP}:${PG_PORT}:5432"]
    volumes:
      # postgres 18 images keep data in /var/lib/postgresql/18/docker; mount the parent
      - pg_data:/var/lib/postgresql
      - ./postgres/init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U ${PG_USER} -d ${PG_DB}"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 30s

  pgbouncer:
    image: ${PGBOUNCER_IMAGE}
    restart: unless-stopped
    depends_on: { postgres: { condition: service_healthy } }
    environment:
      # entrypoint writes "<user>" "<plain pw>" to userlist.txt (needed for scram passthrough)
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_USER: ${PG_USER}
      DB_PASSWORD: ${PG_PASSWORD}
      AUTH_TYPE: scram-sha-256
      POOL_MODE: session
      MAX_CLIENT_CONN: "${PGBOUNCER_MAX_CLIENT_CONN}"
      DEFAULT_POOL_SIZE: "${PGBOUNCER_POOL_SIZE}"
      ADMIN_USERS: ${PG_USER}
      LISTEN_PORT: "5432"
    ports: ["${PRIVATE_IP}:${PGBOUNCER_PORT}:5432"]
    healthcheck:
      # "pgbouncer" admin DB is virtual: checks the pooler without hitting postgres
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432 -U ${PG_USER} -d pgbouncer"]
      interval: 5s
      timeout: 5s
      retries: 30

  mysql:
    image: ${MYSQL_IMAGE}
    restart: unless-stopped
    environment: { MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASSWORD}" }
    ports: ["${PRIVATE_IP}:${MYSQL_PORT}:3306"]
    volumes: [mysql_data:/var/lib/mysql]
    healthcheck:
      # 127.0.0.1 (TCP) only answers after init finishes (init server runs without networking)
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 5s
      timeout: 5s
      retries: 60
      start_period: 30s

  mariadb:
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    ports: ["${PRIVATE_IP}:${MARIADB_PORT}:3306"]
    volumes: [mariadb_data:/var/lib/mysql]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 60
      start_period: 30s

volumes: { pg_data: {}, mysql_data: {}, mariadb_data: {} }
EOF
  dc config -q
}

start_stack() { # $1 = extra build flags
  log "Building and starting"
  # shellcheck disable=SC2086
  dc build --pull ${1:-}
  dc pull --ignore-buildable 2>/dev/null || dc pull pgbouncer mysql mariadb
  dc up -d --wait --wait-timeout 300
}

firewall() {
  log "Firewall"
  if command -v ufw >/dev/null 2>&1; then
    for p in "$PG_PORT" "$PGBOUNCER_PORT" "$MYSQL_PORT" "$MARIADB_PORT"; do
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
  dc exec -T postgres pg_isready -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB"
  echo "-- extensions in $PG_DB:"
  dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" \
    -c "select extname, extversion from pg_extension order by 1;"
  echo "-- extensions in template1 (inherited by new tenant DBs):"
  dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d template1 -tAc \
    "select string_agg(extname, ', ' order by extname) from pg_extension;"
  echo "-- pgbouncer (via docker network pgbouncer:5432, scram; host port $PRIVATE_IP:6432):"
  dc exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 "host=pgbouncer port=5432 user=$PG_USER dbname=$PG_DB sslmode=disable" \
    -tAc "select 'pgbouncer ok: ' || version();"
  echo "-- direct TCP with password (via 127.0.0.1:5432):"
  dc exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 "host=127.0.0.1 port=5432 user=$PG_USER dbname=$PG_DB sslmode=disable" -tAc "select 'postgres ok';"
  echo "-- mysql:"
  dc exec -T mysql sh -c 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null; mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" -NBe "select version()" 2>/dev/null'
  echo "-- mariadb:"
  dc exec -T mariadb healthcheck.sh --connect --innodb_initialized && echo "mariadb healthcheck ok"
  dc exec -T mariadb sh -c 'mariadb-admin ping -uroot -p"$MARIADB_ROOT_PASSWORD"; mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -NBe "select version()"'
  echo "ALL CHECKS PASSED"
}

cmd_env() {
  need_stack; load_env
  cat <<EOF
# paste into $WEB_ENV on the web server, then redeploy in Ploi
# (or save to a file and run scripts/web/update-env-db.sh --from <file>)
DB_CONNECTION=pgsql
DB_HOST=$PRIVATE_IP
DB_PORT=$PG_PORT
DB_DATABASE=$PG_DB
DB_USERNAME=$PG_USER
DB_PASSWORD=$PG_PASSWORD
EOF
}

summary() {
  log "Done"
  cat <<EOF
PostgreSQL + PostGIS + pgvector : $PRIVATE_IP:$PG_PORT  (user/db: $PG_USER/$PG_DB)
PgBouncer (session mode)        : $PRIVATE_IP:$PGBOUNCER_PORT
MySQL ($MYSQL_IMAGE)            : $PRIVATE_IP:$MYSQL_PORT  (root)
MariaDB ($MARIADB_IMAGE)        : $PRIVATE_IP:$MARIADB_PORT  (root)
MySQL / MariaDB root passwords are in $DB_DIR/.env (chmod 600) - not printed.

EOF
  cmd_env
  echo
  echo "Then redeploy the site in Ploi (config is cached at deploy time)."
}

cmd_install() {
  need_root; banner install; ensure_docker
  mkdir -p "$DB_DIR"
  if [ -f "$DB_DIR/.env" ]; then echo "keeping existing $DB_DIR/.env"; else new_env; fi
  write_files; start_stack; firewall; cmd_verify; summary
}

cmd_reset() {
  need_root; banner reset
  echo "This will DELETE all PostgreSQL, MySQL and MariaDB data in $DB_DIR"
  echo "(containers, volumes, image $PG_IMAGE) and create NEW passwords. Backups in $BACKUP_DIR are kept."
  confirm RESET
  ensure_docker
  log "Tearing down old stack"
  mkdir -p "$DB_DIR"; cd "$DB_DIR"
  if [ -f docker-compose.yml ]; then
    [ -f stack.env ] || write_stack_env
    dc down -v --remove-orphans || warn "compose down reported errors"
  fi
  local proj v; proj="$(basename "$DB_DIR")"
  for v in pg_data mysql_data mariadb_data; do docker volume rm -f "${proj}_${v}" >/dev/null 2>&1 || true; done
  docker image rm -f "$PG_IMAGE" >/dev/null 2>&1 || true
  if [ -f .env ]; then
    local b; b="/root/db-env-backup-$(date +%Y%m%d-%H%M%S)"
    (umask 077; cp .env "$b"); chmod 600 "$b"; echo "old .env backed up to $b"
  fi
  rm -rf "${DB_DIR:?}/postgres" "${DB_DIR:?}/docker-compose.yml" "${DB_DIR:?}/stack.env" "${DB_DIR:?}/.env"
  new_env; write_files; start_stack --no-cache; firewall; cmd_verify; summary
}

cmd_backup() {
  need_root; need_stack
  local dest; dest="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"
  (umask 077; mkdir -p "$dest")
  log "Backing up to $dest"
  dc exec -T postgres pg_dumpall -U "$PG_USER" --clean --if-exists | gzip > "$dest/postgres.sql.gz"
  # MySQL/MariaDB: user databases only (system schemas are skipped so a restore never
  # overwrites root/users and the passwords in .env stay valid)
  dc exec -T mysql sh -c 'P="$MYSQL_ROOT_PASSWORD"; DBS=$(mysql -h 127.0.0.1 -uroot -p"$P" -NBe "select schema_name from information_schema.schemata where schema_name not in (\"mysql\",\"sys\",\"information_schema\",\"performance_schema\")" 2>/dev/null); [ -z "$DBS" ] && exit 0; exec mysqldump -h 127.0.0.1 -uroot -p"$P" --databases $DBS --single-transaction --routines --events --triggers 2>/dev/null' | gzip > "$dest/mysql.sql.gz"
  dc exec -T mariadb sh -c 'P="$MARIADB_ROOT_PASSWORD"; DBS=$(mariadb -uroot -p"$P" -NBe "select schema_name from information_schema.schemata where schema_name not in (\"mysql\",\"sys\",\"information_schema\",\"performance_schema\")"); [ -z "$DBS" ] && exit 0; exec mariadb-dump -uroot -p"$P" --databases $DBS --single-transaction --routines --events --triggers' | gzip > "$dest/mariadb.sql.gz"
  local f; for f in "$dest"/*.gz; do gzip -t "$f"; done
  chmod 600 "$dest"/*.gz
  ls -lh "$dest"
  # retention
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do
    echo "pruning $old"; rm -rf "$old"
  done
  echo "backup ok: $dest"
}

cmd_restore() {
  need_root; need_stack
  local src="${1:-}" what="${2:-all}"
  { [ -n "$src" ] && [ -d "$src" ]; } || die "usage: restore <backup-dir> [postgres|mysql|mariadb|all]"
  case "$what" in postgres|mysql|mariadb|all) ;; *) die "unknown target: $what" ;; esac
  banner "restore $what from $src"
  echo "This OVERWRITES current $what data with the backup."
  confirm RESTORE
  if [ "$what" = all ] || [ "$what" = postgres ]; then
    log "postgres"
    dc stop pgbouncer >/dev/null   # release pooled connections to $PG_DB
    # dump includes DROP/CREATE ROLE for $PG_USER; we are connected as it, so skip those lines
    gunzip -c "$src/postgres.sql.gz" | grep -vE "^(DROP|CREATE|ALTER) ROLE (IF EXISTS )?${PG_USER}\\b" \
      | dc exec -T postgres psql -q -v ON_ERROR_STOP=0 -U "$PG_USER" -d postgres >/dev/null
    dc up -d --wait pgbouncer
  fi
  if [ "$what" = all ] || [ "$what" = mysql ]; then
    log "mysql"
    gunzip -c "$src/mysql.sql.gz" | dc exec -T mysql sh -c 'exec mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null'
  fi
  if [ "$what" = all ] || [ "$what" = mariadb ]; then
    log "mariadb"
    gunzip -c "$src/mariadb.sql.gz" | dc exec -T mariadb sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
  fi
  echo "restore done"
}

cmd_cron_install() {
  need_root
  cat > "$CRON_FILE" <<EOF
# $TOOL_NAME - daily backup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$CRON_TIME root DBM_CONFIG=$DBM_CONFIG DB_DIR=$DB_DIR BACKUP_DIR=$BACKUP_DIR KEEP=$KEEP $SELF backup >> $CRON_LOG 2>&1
EOF
  chmod 644 "$CRON_FILE"; echo "installed $CRON_FILE:"; cat "$CRON_FILE"
}

cmd_cron_remove() { need_root; rm -f "$CRON_FILE"; echo "removed $CRON_FILE"; }

cmd_logs() { need_stack; dc logs -f --tail=200 "$@"; }

cmd_uninstall() {
  need_root
  local purge=0; [ "${1:-}" = "--purge" ] && purge=1
  banner "uninstall$([ $purge = 1 ] && echo ' --purge')"
  if [ "$purge" = 1 ]; then
    echo "This DELETES all data, backups in $BACKUP_DIR, the image and $DB_DIR."
    confirm PURGE
  fi
  if [ -f "$DB_DIR/docker-compose.yml" ]; then
    cd "$DB_DIR"
    if [ "$purge" = 1 ]; then dc down -v --remove-orphans; else dc down --remove-orphans; fi
  fi
  if [ "$purge" = 1 ]; then
    docker image rm -f "$PG_IMAGE" >/dev/null 2>&1 || true
    rm -f "$CRON_FILE"; cd /; rm -rf "${DB_DIR:?}"
    echo "purged (ufw rules left in place; remove with: ufw status numbered / ufw delete N)"
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
    --config) skip_next=1 ;;
    --version) echo "$TOOL_NAME $VERSION"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD="${1:-help}"; shift || true
detect_ip
case "$CMD" in help|-h|--help) ;; *) guard_host; need_ip ;; esac
case "$CMD" in
  install)      cmd_install ;;
  reset)        cmd_reset ;;
  status)       cmd_status ;;
  verify)       cmd_verify ;;
  env)          cmd_env ;;
  backup)       cmd_backup ;;
  restore)      cmd_restore "$@" ;;
  cron-install) cmd_cron_install ;;
  cron-remove)  cmd_cron_remove ;;
  logs)         cmd_logs "$@" ;;
  uninstall)    cmd_uninstall "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $CMD" ;;
esac
