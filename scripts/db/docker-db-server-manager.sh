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
#    init [file]        write a starter config for this host (detects IP and VPC)
#    install            first-time setup; keeps an existing .env and data
#    reset              DESTROY everything and start over with new passwords
#    status             containers, health, ports
#    verify             run all connection / extension checks
#    env [engine]       print the DB_* lines for the web server's .env
#    create-db <name> [engine]   new database + user with its own password
#    doctor             read-only security/health checks (exposure, ufw, updates)
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
#  ENGINES
#    ENABLE_POSTGRES ENABLE_PGBOUNCER ENABLE_MYSQL ENABLE_MARIADB (1/0, default 1).
#    Disabled engines get no container, port, firewall rule, backup or check.
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
VERSION="1.1.0"

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
ENABLE_POSTGRES="${ENABLE_POSTGRES:-1}"
ENABLE_PGBOUNCER="${ENABLE_PGBOUNCER:-1}"
ENABLE_MYSQL="${ENABLE_MYSQL:-1}"
ENABLE_MARIADB="${ENABLE_MARIADB:-1}"
PG_EXTENSIONS="${PG_EXTENSIONS:-vector postgis pg_trgm pgcrypto uuid-ossp pg_stat_statements}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"        # backup refuses to start below this
BACKUP_HOOK="${BACKUP_HOOK:-}"            # optional: run after a good backup, e.g. rclone copy "$1" spaces:bucket/db
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/docker-db-server-backup}"
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
  local v; for v in ENABLE_POSTGRES ENABLE_PGBOUNCER ENABLE_MYSQL ENABLE_MARIADB; do
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
$TOOL_NAME

Usage: $(basename "$0") <command> [args] [--yes]

Commands:
  init [file]
      Writes a starter config with this host's private IP and VPC range
      (stdout, or FILE). Review it, then install it as $DBM_CONFIG.
        ./docker-db-server-manager.sh init > db-server.conf

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

  create-db <name> [postgres|mysql|mariadb]
      Creates database <name> and user <name> with a new random password and
      prints its DB_* lines. Postgres DBs get the template1 extensions.
        sudo ./docker-db-server-manager.sh create-db shop
        sudo ./docker-db-server-manager.sh create-db blog mysql

  doctor
      Read-only checks: DB ports bound only to the private IP, ufw state and
      default policy, unattended-upgrades, pending reboot, disk space.
        sudo ./docker-db-server-manager.sh doctor

  backup
      Dumps PostgreSQL (pg_dumpall), MySQL and MariaDB (user DBs, not system) into
      \$BACKUP_DIR/<timestamp>/ as gzip, plus MySQL/MariaDB users+grants (grants-*.sql.gz,
      applied by hand). Needs \$MIN_FREE_MB free; keeps the newest \$KEEP (default 7);
      runs \$BACKUP_HOOK <dir> afterwards if set (offsite copy).
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

Engines: ENABLE_POSTGRES=$ENABLE_POSTGRES ENABLE_PGBOUNCER=$ENABLE_PGBOUNCER ENABLE_MYSQL=$ENABLE_MYSQL ENABLE_MARIADB=$ENABLE_MARIADB
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

  local ext sql=""
  for ext in $PG_EXTENSIONS; do sql="${sql}CREATE EXTENSION IF NOT EXISTS \"$ext\";
"; done
  cat > postgres/init/10-extensions.sql <<EOF
-- runs once, on an empty data dir. template1 => every database created later gets these.
\\set ON_ERROR_STOP on
\\c template1
${sql}\\c $PG_DB
${sql}
EOF

write_stack_env


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

EOF
  fi
  if on "$ENABLE_PGBOUNCER"; then cat <<'EOF'
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

EOF
  fi
  if on "$ENABLE_MYSQL"; then cat <<'EOF'
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

EOF
  fi
  if on "$ENABLE_MARIADB"; then cat <<'EOF'
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

EOF
  fi
  local vols=""
  on "$ENABLE_POSTGRES" && vols="$vols pg_data: {},"
  on "$ENABLE_MYSQL" && vols="$vols mysql_data: {},"
  on "$ENABLE_MARIADB" && vols="$vols mariadb_data: {},"
  echo "volumes: {${vols%,} }"
} > docker-compose.yml
  dc config -q
}

start_stack() { # $1 = extra build flags
  log "Building and starting"
  # shellcheck disable=SC2086
  if on "$ENABLE_POSTGRES"; then dc build --pull ${1:-}; fi
  # shellcheck disable=SC2046  # service names never contain spaces
  dc pull --ignore-buildable 2>/dev/null || dc pull $(dc config --services | grep -vx postgres || true)
  dc up -d --wait --wait-timeout 300
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
    dc exec -T postgres pg_isready -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB"
    echo "-- extensions in $PG_DB:"
    dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" \
      -c "select extname, extversion from pg_extension order by 1;"
    echo "-- extensions in template1 (inherited by new DBs):"
    dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d template1 -tAc \
      "select string_agg(extname, ', ' order by extname) from pg_extension;"
    echo "-- direct TCP with password (via 127.0.0.1:5432):"
    dc exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
      psql -v ON_ERROR_STOP=1 "host=127.0.0.1 port=5432 user=$PG_USER dbname=$PG_DB sslmode=disable" -tAc "select 'postgres ok';"
  fi
  if on "$ENABLE_PGBOUNCER"; then
    echo "-- pgbouncer (via docker network pgbouncer:5432, scram; host port $PRIVATE_IP:6432):"
    dc exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
      psql -v ON_ERROR_STOP=1 "host=pgbouncer port=5432 user=$PG_USER dbname=$PG_DB sslmode=disable" \
      -tAc "select 'pgbouncer ok: ' || version();"
  fi
  if on "$ENABLE_MYSQL"; then
    echo "-- mysql:"
    dc exec -T mysql sh -c 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null; mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" -NBe "select version()" 2>/dev/null'
  fi
  if on "$ENABLE_MARIADB"; then
    echo "-- mariadb:"
    dc exec -T mariadb healthcheck.sh --connect --innodb_initialized && echo "mariadb healthcheck ok"
    dc exec -T mariadb sh -c 'mariadb-admin ping -uroot -p"$MARIADB_ROOT_PASSWORD"; mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -NBe "select version()"'
  fi
  echo "ALL CHECKS PASSED"
}

cmd_env() { # [engine]: postgres (default when enabled), mysql, mariadb
  need_stack; load_env
  local e="${1:-$(engines | cut -d' ' -f1)}"
  echo "# paste into $WEB_ENV on the web server, then redeploy"
  echo "# (or save to a file and run scripts/web/update-env-db.sh --from <file>)"
  case "$e" in
    postgres) on "$ENABLE_POSTGRES" || die "postgres is disabled"
      printf 'DB_CONNECTION=pgsql\nDB_HOST=%s\nDB_PORT=%s\nDB_DATABASE=%s\nDB_USERNAME=%s\nDB_PASSWORD=%s\n' \
        "$PRIVATE_IP" "$PG_PORT" "$PG_DB" "$PG_USER" "$PG_PASSWORD" ;;
    mysql|mariadb) on "$( [ "$e" = mysql ] && echo "$ENABLE_MYSQL" || echo "$ENABLE_MARIADB")" || die "$e is disabled"
      echo "# no app user exists yet for $e: run  create-db <name> $e  and use its lines"
      printf 'DB_CONNECTION=%s\nDB_HOST=%s\nDB_PORT=%s\n' "$e" "$PRIVATE_IP" \
        "$( [ "$e" = mysql ] && echo "$MYSQL_PORT" || echo "$MARIADB_PORT")" ;;
    *) die "usage: env [postgres|mysql|mariadb]" ;;
  esac
}

cmd_create_db() { # <name> [engine]
  need_root; need_stack; load_env
  local name="${1:-}" e="${2:-$(engines | cut -d' ' -f1)}" pw port
  [[ "$name" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "usage: create-db <name> [engine]  (name: a-z 0-9 _, max 63)"
  pw="$(openssl rand -hex 24)"
  case "$e" in
    postgres) on "$ENABLE_POSTGRES" || die "postgres is disabled"
      dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -tAc "select 1 from pg_roles where rolname='$name'" | grep -q 1 \
        && die "role $name already exists in postgres"
      dc exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres \
        -c "CREATE ROLE \"$name\" LOGIN PASSWORD '$pw';" -c "CREATE DATABASE \"$name\" OWNER \"$name\";"
      port="$PG_PORT"; e=pgsql ;;
    mysql|mariadb)
      local svc="$e" cli=mysql rootvar=MYSQL_ROOT_PASSWORD
      if [ "$e" = mariadb ]; then on "$ENABLE_MARIADB" || die "mariadb is disabled"; cli=mariadb; rootvar=MARIADB_ROOT_PASSWORD; port="$MARIADB_PORT"
      else on "$ENABLE_MYSQL" || die "mysql is disabled"; port="$MYSQL_PORT"; fi
      dc exec -T -e N="$name" -e PW="$pw" "$svc" sh -c "exec $cli -h 127.0.0.1 -uroot -p\"\$$rootvar\" 2>/dev/null -e \"
        CREATE DATABASE \\\`\$N\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER '\$N'@'%' IDENTIFIED BY '\$PW';
        GRANT ALL PRIVILEGES ON \\\`\$N\\\`.* TO '\$N'@'%';\"" ;;
    *) die "usage: create-db <name> [postgres|mysql|mariadb]" ;;
  esac
  echo "# created database and user '$name' ($e). Save these now; the password is not stored on this server."
  printf 'DB_CONNECTION=%s\nDB_HOST=%s\nDB_PORT=%s\nDB_DATABASE=%s\nDB_USERNAME=%s\nDB_PASSWORD=%s\n' "$e" "$PRIVATE_IP" "$port" "$name" "$name" "$pw"
  [ "$e" != pgsql ] || ! on "$ENABLE_PGBOUNCER" || echo "# note: PgBouncer only knows $PG_USER; connect this user directly on $PG_PORT"
}

cmd_doctor() { # read-only
  local bad=0 p l
  log "Exposure: DB ports must listen on $PRIVATE_IP only"
  for p in $(enabled_ports); do
    l="$(ss -Htln "sport = :$p" 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
    if [ -z "$l" ]; then echo "  $p: not listening"
    elif echo "$l" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):'; then echo "  $p: PUBLIC ($l) - PROBLEM"; bad=1
    else echo "  $p: ok ($l)"; fi
  done
  echo "  (Docker-published ports bypass ufw; binding to the private IP is what keeps them off the internet.)"
  log "Firewall"
  if command -v ufw >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    ufw status verbose | grep -E '^(Status|Default):' | sed 's/^/  /'
    ufw status verbose | grep -q 'deny (incoming)' || { echo "  default incoming is not deny - PROBLEM"; bad=1; }
  else echo "  ufw: unknown (needs root / ufw)"; fi
  log "Updates"
  if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then echo "  unattended-upgrades: enabled"
  else echo "  unattended-upgrades: not enabled (apt install unattended-upgrades; dpkg-reconfigure -plow unattended-upgrades)"; fi
  if [ -f /var/run/reboot-required ]; then echo "  reboot required: yes (sudo reboot in a quiet period)"; else echo "  reboot required: no"; fi
  log "Disk"
  df -h / "$DB_DIR" 2>/dev/null | sed 's/^/  /'
  log "Backups"
  if [ -d "$BACKUP_DIR" ]; then echo "  newest: $(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)"
  else echo "  none yet in $BACKUP_DIR"; fi
  if [ -f "$CRON_FILE" ]; then echo "  cron: $CRON_FILE"; else echo "  cron: not installed (cron-install)"; fi
  if [ "$bad" = 0 ]; then echo "doctor: no problems found"; else die "doctor: problems found (see above)"; fi
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
# Bootstrap Postgres user and database
PG_USER=$PG_USER
PG_DB=$PG_DB
#PG_EXTENSIONS=$PG_EXTENSIONS
# Offsite copy after each backup (optional), e.g.:
#BACKUP_HOOK=rclone copy "\$1" spaces:my-bucket/db/\$(basename "\$1")
EOF
  [ "$out" = /dev/stdout ] || echo "wrote $out"
  [ -n "$ip" ] || warn "$PRIVATE_IFACE has no IPv4 here; fill in PRIVATE_IP/VPC_CIDR by hand"
}

summary() {
  log "Done"
  on "$ENABLE_POSTGRES"  && echo "PostgreSQL ($PG_IMAGE)  : $PRIVATE_IP:$PG_PORT  (user/db: $PG_USER/$PG_DB)"
  on "$ENABLE_PGBOUNCER" && echo "PgBouncer (session mode) : $PRIVATE_IP:$PGBOUNCER_PORT"
  on "$ENABLE_MYSQL"     && echo "MySQL ($MYSQL_IMAGE)     : $PRIVATE_IP:$MYSQL_PORT  (root)"
  on "$ENABLE_MARIADB"   && echo "MariaDB ($MARIADB_IMAGE) : $PRIVATE_IP:$MARIADB_PORT  (root)"
  echo "Root passwords are in $DB_DIR/.env (chmod 600) - not printed."
  echo
  cmd_env
  echo
  echo "Then redeploy the web app (Laravel caches config at deploy time)."
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
  local ts free dest tmp
  ts="$(date +%Y%m%d-%H%M%S)"; dest="$BACKUP_DIR/$ts"; tmp="$BACKUP_DIR/.partial-$ts"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  free="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
  [ "${free:-0}" -ge "$MIN_FREE_MB" ] || die "only ${free}MB free in $BACKUP_DIR (MIN_FREE_MB=$MIN_FREE_MB); not starting a backup"
  rm -rf "$BACKUP_DIR"/.partial-*          # leftovers of an interrupted run
  (umask 077; mkdir -p "$tmp")
  log "Backing up to $dest"
  if on "$ENABLE_POSTGRES"; then
    dc exec -T postgres pg_dumpall -U "$PG_USER" --clean --if-exists | gzip > "$tmp/postgres.sql.gz"
  fi
  # MySQL/MariaDB: user databases only (system schemas are skipped so a restore never
  # overwrites root/users and the passwords in .env stay valid). Users and grants go to
  # a separate grants-*.sql.gz you can apply by hand.
  local users_sql='select concat("\x27",user,"\x27@\x27",host,"\x27") from mysql.user where user not in ("root","mysql.sys","mysql.session","mysql.infoschema","mariadb.sys","healthcheck","")'
  if on "$ENABLE_MYSQL"; then
    dc exec -T mysql sh -c 'P="$MYSQL_ROOT_PASSWORD"; DBS=$(mysql -h 127.0.0.1 -uroot -p"$P" -NBe "select schema_name from information_schema.schemata where schema_name not in (\"mysql\",\"sys\",\"information_schema\",\"performance_schema\")" 2>/dev/null); [ -z "$DBS" ] && exit 0; exec mysqldump -h 127.0.0.1 -uroot -p"$P" --databases $DBS --single-transaction --routines --events --triggers 2>/dev/null' | gzip > "$tmp/mysql.sql.gz"
    dc exec -T -e Q="$users_sql" mysql sh -c 'P="$MYSQL_ROOT_PASSWORD"; for u in $(mysql -h 127.0.0.1 -uroot -p"$P" -NBe "$Q" 2>/dev/null); do mysql -h 127.0.0.1 -uroot -p"$P" -NBe "show create user $u; show grants for $u" 2>/dev/null | sed "s/\$/;/"; done' | gzip > "$tmp/grants-mysql.sql.gz"
  fi
  if on "$ENABLE_MARIADB"; then
    dc exec -T mariadb sh -c 'P="$MARIADB_ROOT_PASSWORD"; DBS=$(mariadb -uroot -p"$P" -NBe "select schema_name from information_schema.schemata where schema_name not in (\"mysql\",\"sys\",\"information_schema\",\"performance_schema\")"); [ -z "$DBS" ] && exit 0; exec mariadb-dump -uroot -p"$P" --databases $DBS --single-transaction --routines --events --triggers' | gzip > "$tmp/mariadb.sql.gz"
    dc exec -T -e Q="$users_sql" mariadb sh -c 'P="$MARIADB_ROOT_PASSWORD"; for u in $(mariadb -uroot -p"$P" -NBe "$Q"); do mariadb -uroot -p"$P" -NBe "show create user $u; show grants for $u" | sed "s/\$/;/"; done' | gzip > "$tmp/grants-mariadb.sql.gz"
  fi
  local f; for f in "$tmp"/*.gz; do gzip -t "$f"; done
  chmod 600 "$tmp"/*.gz
  mv "$tmp" "$dest"                        # only complete backups get a timestamp name
  ls -lh "$dest"
  # retention (complete backups only)
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do
    echo "pruning $old"; rm -rf "$old"
  done
  if [ -n "$BACKUP_HOOK" ]; then
    log "Backup hook"
    bash -c "$BACKUP_HOOK" _ "$dest" || die "BACKUP_HOOK failed (the local backup in $dest is fine)"
  fi
  echo "backup ok: $dest"
}

cmd_restore() {
  need_root; need_stack
  local src="${1:-}" what="${2:-all}"
  { [ -n "$src" ] && [ -d "$src" ]; } || die "usage: restore <backup-dir> [postgres|mysql|mariadb|all]"
  case "$what" in postgres|mysql|mariadb|all) ;; *) die "unknown target: $what" ;; esac
  [ "$what" = all ] || echo " $(engines) " | grep -q " $what " || die "$what is disabled"
  banner "restore $what from $src"
  echo "This OVERWRITES current $what data with the backup."
  confirm RESTORE
  want() { { [ "$what" = all ] || [ "$what" = "$1" ]; } && echo " $(engines) " | grep -q " $1 " \
    && { [ -f "$src/$1.sql.gz" ] || { warn "no $1.sql.gz in $src - skipping"; return 1; }; }; }
  if want postgres; then
    log "postgres"
    if on "$ENABLE_PGBOUNCER"; then dc stop pgbouncer >/dev/null; fi   # release pooled connections
    # dump includes DROP/CREATE ROLE for $PG_USER; we are connected as it, so skip those lines
    gunzip -c "$src/postgres.sql.gz" | grep -vE "^(DROP|CREATE|ALTER) ROLE (IF EXISTS )?${PG_USER}\\b" \
      | dc exec -T postgres psql -q -v ON_ERROR_STOP=0 -U "$PG_USER" -d postgres >/dev/null
    if on "$ENABLE_PGBOUNCER"; then dc up -d --wait pgbouncer; fi
  fi
  if want mysql; then
    log "mysql"
    gunzip -c "$src/mysql.sql.gz" | dc exec -T mysql sh -c 'exec mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null'
  fi
  if want mariadb; then
    log "mariadb"
    gunzip -c "$src/mariadb.sql.gz" | dc exec -T mariadb sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
  fi
  echo "restore done (users/grants are in grants-*.sql.gz if you need them)"
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
  if [ -d "$(dirname "$LOGROTATE_FILE")" ]; then
    printf '%s {\n  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n}\n' "$CRON_LOG" > "$LOGROTATE_FILE"
    echo "installed $LOGROTATE_FILE (weekly, 8 kept)"
  fi
}

cmd_cron_remove() { need_root; rm -f "$CRON_FILE" "$LOGROTATE_FILE"; echo "removed $CRON_FILE"; }

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
    rm -f "$CRON_FILE" "$LOGROTATE_FILE"; cd /; rm -rf "${DB_DIR:?}"
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
case "$CMD" in help|-h|--help|init) ;; *) check_engines; guard_host; need_ip ;; esac
case "$CMD" in
  install)      cmd_install ;;
  reset)        cmd_reset ;;
  status)       cmd_status ;;
  verify)       cmd_verify ;;
  env)          cmd_env "$@" ;;
  init)         cmd_init "$@" ;;
  create-db)    cmd_create_db "$@" ;;
  doctor)       cmd_doctor ;;
  backup)       cmd_backup ;;
  restore)      cmd_restore "$@" ;;
  cron-install) cmd_cron_install ;;
  cron-remove)  cmd_cron_remove ;;
  logs)         cmd_logs "$@" ;;
  uninstall)    cmd_uninstall "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $CMD" ;;
esac
