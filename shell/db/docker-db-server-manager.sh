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
#    upgrade|apply      guided safe update: preflight, diff, backup, savepoint, apply,
#                       verify, auto-rollback (live servers: use this, not install)
#    install            first-time setup; keeps an existing .env and data
#    reset              DESTROY everything and start over with new passwords
#    status             containers, health, ports
#    verify             run all connection / extension checks
#    env [engine]       print the DB_* lines for the web server's .env
#    create-db <name> [engine] [--extensions L] [--readonly-user] [--out F]
#                       new database + owner user (own password, PgBouncer-ready)
#    create-user <u> <db> [engine] [--readonly] [--out F]   extra user on a db
#    grant <u> <db> [engine] [--readonly|--readwrite]
#    drop-db <name> [engine] | drop-user <u> [engine]   (DESTRUCTIVE, type DROP)
#    rotate-password <u> [engine] [--out F]
#    list-dbs [engine|all] | list-users [engine|all]
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
#    ENABLE_ADMINER (default 0): optional Adminer web UI on 127.0.0.1:$ADMINER_PORT
#    only (never the VPC, no ufw rule); open it through an SSH tunnel.
#
#  ENVIRONMENT OVERRIDES (most common)
#    PRIVATE_IP   bind address (default: eth1 IPv4; required if eth1 is missing)
#    EXPECTED_PRIVATE_IP  abort unless this IP is on the host (wrong-server guard)
#    VPC_CIDR     ufw source range (default 10.0.0.0/8 - set your VPC range)
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
# shellcheck disable=SC1091,SC2016
set -euo pipefail
trap 'echo "!! ERROR: line $LINENO: \"$BASH_COMMAND\" failed" >&2' ERR

TOOL_NAME="Docker DB Server Setup Manager"
VERSION="1.3.0"

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
$TOOL_NAME

Usage: $(basename "$0") <command> [args] [--yes]

Commands:
  init [file]
      Writes a starter config with this host's private IP and VPC range
      (stdout, or FILE). Review it, then install it as $DBM_CONFIG.
        ./docker-db-server-manager.sh init > db-server.conf

  upgrade | apply [--dry-run] [--yes|--non-interactive] [--snapshot|--snapshot-taken|--no-snapshot]
      Guided, safe update of an installed stack (use this, not install, on a live server):
      preflight (config, Docker, disk, health, port bindings, versions) -> diff of the
      generated files -> confirm -> optional DigitalOcean snapshot -> verified backup ->
      savepoint (compose, stack.env, .env, postgres/, manager, config, pgbouncer.ini,
      image ids) -> apply -> verify + doctor. Any failure rolls back automatically to the
      savepoint and re-verifies. Data is never restored automatically. Locked, logged to
      $DBM_LOG with secrets redacted. Idempotent: "already up to date" if nothing changes.
        sudo ./docker-db-server-manager.sh upgrade --dry-run
        sudo ./docker-db-server-manager.sh upgrade
        sudo ./docker-db-server-manager.sh upgrade --yes --no-snapshot      # automation

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

  create-db <name> [engine] [--extensions citext,hstore] [--readonly-user] [--out FILE]
      Creates database <name> owned by a new user <name> (random password; PUBLIC
      gets no CONNECT). Postgres DBs inherit the template1 extensions
      ($PG_EXTENSIONS); --extensions adds more. --readonly-user also makes <name>_ro.
      Credentials print once (or go to a new chmod 600 FILE with --out).
        sudo ./docker-db-server-manager.sh create-db shop
        sudo ./docker-db-server-manager.sh create-db shop --extensions citext,hstore --readonly-user
        sudo ./docker-db-server-manager.sh create-db blog mysql --out /root/blog.creds

  create-user <user> <db> [engine] [--readonly] [--out FILE]
  grant <user> <db> [engine] [--readonly|--readwrite]
  rotate-password <user> [engine] [--out FILE]
  list-dbs [engine|all] | list-users [engine|all]
  drop-db <name> [engine] | drop-user <user> [engine]   (DESTRUCTIVE, type DROP)
      Least-privilege user management. Postgres users work through PgBouncer
      ($PGBOUNCER_PORT) at once (auth_query). Protected: $PG_USER, $PG_DB, root, system DBs.
        sudo ./docker-db-server-manager.sh create-user shop_report shop --readonly
        sudo ./docker-db-server-manager.sh rotate-password shop

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

  logs [postgres|pgbouncer|mysql|mariadb|adminer]
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
Admin UI: ENABLE_ADMINER=$ENABLE_ADMINER ($ADMINER_IMAGE on 127.0.0.1:$ADMINER_PORT only; open via SSH tunnel, see docs/guides/connections.md)
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
ADMINER_IMAGE=$ADMINER_IMAGE
ADMINER_PORT=$ADMINER_PORT
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
# apt packages are GPG-signed; ca-certificates first so the pgdg repo can switch to https
RUN apt-get -o Acquire::Retries=5 update \
 && apt-get -o Acquire::Retries=5 install -y --no-install-recommends ca-certificates \
 && for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do [ -f "$f" ] && sed -i 's|http://apt.postgresql.org|https://apt.postgresql.org|g' "$f"; done; \
 apt-get -o Acquire::Retries=5 update \
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
      # any Postgres login role can use the pooler: PgBouncer looks the role up
      # through PG_USER (default auth_query on pg_authid), no userlist edits needed
      AUTH_USER: ${PG_USER}
      AUTH_DBNAME: postgres
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
  echo "# (or save to a file and run shell/web/update-env-db.sh --from <file>)"
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

# ---- databases and users ------------------------------------------------------
# All SQL goes to the client on stdin, so generated passwords never appear in
# process arguments (ps), shell history or logs. Passwords are printed once to
# stdout, or written to a new chmod 600 file with --out FILE; never stored here.
U_ENGINE="" U_RO=0 U_OUT="" U_EXT="" U_POS=()
parse_user_args() { # fills U_* from: [engine] [--engine E] [--readonly] [--out FILE] [--extensions a,b]
  U_ENGINE="" U_RO=0 U_OUT="" U_EXT="" U_POS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      postgres|pgsql|mysql|mariadb) U_ENGINE="${1/pgsql/postgres}" ;;
      --engine) U_ENGINE="${2:-}"; shift ;;
      --readonly|--ro) U_RO=1 ;;
      --readwrite|--rw) U_RO=0 ;;
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
  local max=63; [ "$U_ENGINE" = postgres ] || max=32
  [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]] && [ "${#1}" -le "$max" ] || die "bad $2 name '$1' (a-z 0-9 _, start with a letter or _, max $max)"
}
valid_exts() { local x; for x in $1; do [[ "$x" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad extension name: $x"; done; }
protected_db() { case "$1" in postgres|template0|template1|mysql|sys|information_schema|performance_schema|"$PG_DB") return 0 ;; esac; return 1; }
protected_user() { case "$1" in postgres|root|mysql|mariadb.sys|mysql.sys|mysql.session|mysql.infoschema|healthcheck|"$PG_USER") return 0 ;; esac; return 1; }
new_password() { openssl rand -hex 24; }

pg_q() { # [db] ; SQL on stdin
  dc exec -T postgres psql -q -X -v ON_ERROR_STOP=1 -U "$PG_USER" -d "${1:-postgres}" -tA -f -
}
my_q() { # engine ; SQL on stdin
  local cli=mysql rv=MYSQL_ROOT_PASSWORD
  [ "$1" = mariadb ] && cli=mariadb rv=MARIADB_ROOT_PASSWORD
  dc exec -T "$1" sh -c "MYSQL_PWD=\"\$$rv\" exec $cli -h 127.0.0.1 -uroot -N -B"
}
pgbouncer_reload() { # new roles work through auth_query at once; RELOAD also refreshes config
  on "$ENABLE_PGBOUNCER" || return 0
  printf 'RELOAD;\n' | dc exec -T -e PGPASSWORD="$PG_PASSWORD" pgbouncer \
    psql -X -q -h 127.0.0.1 -p 5432 -U "$PG_USER" -d pgbouncer -f - >/dev/null 2>&1 \
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
  if [ "$1" = postgres ] && on "$ENABLE_PGBOUNCER"; then
    body="$body
# DB_PORT is PgBouncer; direct Postgres (migrations in transaction pooling, admin) is $PG_PORT"
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

pg_grant_sql() { # user db readonly(0/1) -> SQL for the target db
  local u="$1" d="$2" ro="$3" owner
  owner="$(printf "select pg_get_userbyid(datdba) from pg_database where datname='%s';\n" "$d" | pg_q)"
  [ -n "$owner" ] || die "database $d does not exist in postgres"
  if [ "$ro" = 1 ]; then cat <<SQL
GRANT CONNECT ON DATABASE "$d" TO "$u";
GRANT USAGE ON SCHEMA public TO "$u";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$u";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT SELECT ON TABLES TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT SELECT ON SEQUENCES TO "$u";
SQL
  else cat <<SQL
GRANT CONNECT, TEMPORARY ON DATABASE "$d" TO "$u";
GRANT USAGE, CREATE ON SCHEMA public TO "$u";
GRANT ALL ON ALL TABLES IN SCHEMA public TO "$u";
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT ALL ON TABLES TO "$u";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public GRANT ALL ON SEQUENCES TO "$u";
SQL
  fi
}
my_grant_sql() { # user db readonly
  if [ "$3" = 1 ]; then echo "GRANT SELECT, SHOW VIEW ON \`$2\`.* TO '$1'@'%';"
  else echo "GRANT ALL PRIVILEGES ON \`$2\`.* TO '$1'@'%';"; fi
}
pg_role_exists() { [ "$(printf "select 1 from pg_roles where rolname='%s';\n" "$1" | pg_q)" = 1 ]; }
my_user_exists() { [ "$(printf "select count(*) from mysql.user where user='%s';\n" "$1" | my_q "$2")" != 0 ]; }

cmd_list_dbs() { # [engine|all]
  need_root; need_stack; load_env
  local e list; list="$(engines)"; [ -n "${1:-}" ] && [ "$1" != all ] && list="$1"
  for e in $list; do
    log "$e databases"
    case "$e" in
      postgres) printf '%s\n' "select datname || '  owner=' || pg_get_userbyid(datdba) || '  size=' || pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate order by 1;" | pg_q ;;
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
      postgres) echo "select rolname || case when rolsuper then '  (superuser)' else '' end || '  dbs=' || coalesce((select string_agg(datname, ',') from pg_database d where has_database_privilege(r.rolname, d.datname, 'CONNECT') and not datistemplate and datname<>'postgres'),'') from pg_roles r where rolcanlogin order by 1;" | pg_q ;;
      mysql|mariadb) echo "select concat(user,'@',host) from mysql.user where user not in ('mariadb.sys','mysql.sys','mysql.session','mysql.infoschema','healthcheck','') order by 1;" | my_q "$e" ;;
      *) die "unknown engine: $e" ;;
    esac
  done
}

cmd_create_db() { # <name> [engine] [--extensions a,b] [--readonly-user] [--out FILE]
  local ro_user=0 a args=()
  for a in "$@"; do [ "$a" = --readonly-user ] && ro_user=1 || args+=("$a"); done
  parse_user_args "${args[@]+"${args[@]}"}"
  local name="${U_POS[0]:-}"; [ -n "$name" ] || die "usage: create-db <name> [engine] [--extensions citext,hstore] [--readonly-user] [--out FILE]"
  valid_ident "$name" database; valid_exts "$U_EXT"
  [ -z "$U_EXT" ] || [ "$U_ENGINE" = postgres ] || die "--extensions is for postgres only"
  need_root; need_stack; load_env
  local pw x; pw="$(new_password)"
  case "$U_ENGINE" in
    postgres)
      pg_role_exists "$name" && die "role $name already exists in postgres"
      { printf "CREATE ROLE \"%s\" LOGIN PASSWORD '%s';\n" "$name" "$pw"
        printf 'CREATE DATABASE "%s" OWNER "%s";\n' "$name" "$name"
        printf 'REVOKE ALL ON DATABASE "%s" FROM PUBLIC;\n' "$name"
        # keep the new user out of the main app database too (idempotent)
        printf 'REVOKE CONNECT, TEMPORARY ON DATABASE "%s" FROM PUBLIC;\n' "$PG_DB"; } | pg_q
      # template1 already gave it PG_EXTENSIONS; --extensions adds more (needs superuser, so done here)
      if [ -n "$U_EXT" ]; then
        for x in $U_EXT; do printf 'CREATE EXTENSION IF NOT EXISTS "%s";\n' "$x"; done | pg_q "$name"
      fi
      echo "# extensions in $name: $(echo "select string_agg(extname, ' ' order by extname) from pg_extension;" | pg_q "$name")"
      pgbouncer_reload ;;
    mysql|mariadb)
      my_user_exists "$name" "$U_ENGINE" && die "user $name already exists in $U_ENGINE"
      { printf 'CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$name"
        printf "CREATE USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$name" "$pw"
        my_grant_sql "$name" "$name" 0; } | my_q "$U_ENGINE" ;;
  esac
  local out="$U_OUT"
  print_creds "$U_ENGINE" "$name" "$name" "$pw"
  if [ "$ro_user" = 1 ]; then
    [ -z "$out" ] || U_OUT="$out.readonly"
    cmd_create_user "${name}_ro" "$name" "$U_ENGINE" --readonly ${U_OUT:+--out "$U_OUT"}
  fi
}

cmd_create_user() { # <user> <db> [engine] [--readonly] [--out FILE]
  parse_user_args "$@"
  local u="${U_POS[0]:-}" d="${U_POS[1]:-}"
  [ -n "$u" ] && [ -n "$d" ] || die "usage: create-user <user> <db> [engine] [--readonly] [--out FILE]"
  valid_ident "$u" user; valid_ident "$d" database
  need_root; need_stack; load_env
  local pw; pw="$(new_password)"
  case "$U_ENGINE" in
    postgres)
      pg_role_exists "$u" && die "role $u already exists"
      printf "CREATE ROLE \"%s\" LOGIN PASSWORD '%s';\n" "$u" "$pw" | pg_q
      pg_grant_sql "$u" "$d" "$U_RO" | pg_q "$d"
      pgbouncer_reload ;;
    mysql|mariadb)
      my_user_exists "$u" "$U_ENGINE" && die "user $u already exists in $U_ENGINE"
      { printf "CREATE USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$u" "$pw"; my_grant_sql "$u" "$d" "$U_RO"; } | my_q "$U_ENGINE" ;;
  esac
  echo "# user $u on $d ($U_ENGINE): $([ "$U_RO" = 1 ] && echo read-only || echo read-write)"
  print_creds "$U_ENGINE" "$d" "$u" "$pw"
}

cmd_grant() { # <user> <db> [engine] [--readonly|--readwrite]
  parse_user_args "$@"
  local u="${U_POS[0]:-}" d="${U_POS[1]:-}"
  [ -n "$u" ] && [ -n "$d" ] || die "usage: grant <user> <db> [engine] [--readonly|--readwrite]"
  valid_ident "$u" user; valid_ident "$d" database; protected_user "$u" && die "refusing to change grants of $u"
  need_root; need_stack; load_env
  case "$U_ENGINE" in
    postgres) pg_role_exists "$u" || die "no role $u"; pg_grant_sql "$u" "$d" "$U_RO" | pg_q "$d" ;;
    mysql|mariadb) my_user_exists "$u" "$U_ENGINE" || die "no user $u"; my_grant_sql "$u" "$d" "$U_RO" | my_q "$U_ENGINE" ;;
  esac
  echo "granted $u $([ "$U_RO" = 1 ] && echo read-only || echo read-write) on $d ($U_ENGINE)"
}

cmd_drop_db() { # <name> [engine] (DESTRUCTIVE)
  parse_user_args "$@"; local d="${U_POS[0]:-}"
  [ -n "$d" ] || die "usage: drop-db <name> [engine] [--yes]"
  valid_ident "$d" database; protected_db "$d" && die "refusing to drop protected database $d"
  need_root; need_stack; load_env
  echo "About to DROP database $d on $U_ENGINE (take a backup first: backup)."; confirm DROP
  case "$U_ENGINE" in
    postgres) printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\n' "$d" | pg_q ;;
    mysql|mariadb) printf 'DROP DATABASE IF EXISTS `%s`;\n' "$d" | my_q "$U_ENGINE" ;;
  esac
  echo "dropped database $d ($U_ENGINE)"
}

cmd_drop_user() { # <user> [engine] (DESTRUCTIVE)
  parse_user_args "$@"; local u="${U_POS[0]:-}"
  [ -n "$u" ] || die "usage: drop-user <user> [engine] [--yes]"
  valid_ident "$u" user; protected_user "$u" && die "refusing to drop protected user $u"
  need_root; need_stack; load_env
  echo "About to DROP user $u on $U_ENGINE. Objects it owns are reassigned to $PG_USER (postgres)."; confirm DROP
  case "$U_ENGINE" in
    postgres)
      pg_role_exists "$u" || die "no role $u"
      local d; for d in $(echo "select datname from pg_database where datallowconn;" | pg_q); do
        printf 'REASSIGN OWNED BY "%s" TO "%s";\nDROP OWNED BY "%s";\n' "$u" "$PG_USER" "$u" | pg_q "$d"
      done
      printf 'DROP ROLE "%s";\n' "$u" | pg_q; pgbouncer_reload ;;
    mysql|mariadb) printf "DROP USER IF EXISTS '%s'@'%%';\n" "$u" | my_q "$U_ENGINE" ;;
  esac
  echo "dropped user $u ($U_ENGINE)"
}

cmd_rotate_password() { # <user> [engine] [--out FILE]
  parse_user_args "$@"; local u="${U_POS[0]:-}"
  [ -n "$u" ] || die "usage: rotate-password <user> [engine] [--out FILE]"
  valid_ident "$u" user
  [ "$U_ENGINE" = postgres ] && [ "$u" = "$PG_USER" ] && die "$PG_USER's password is shared with PgBouncer; rotate it with reset, or by hand (docs/reference/db-server.md)"
  protected_user "$u" && die "refusing to rotate $u here"
  need_root; need_stack; load_env
  local pw db; pw="$(new_password)"
  case "$U_ENGINE" in
    postgres) pg_role_exists "$u" || die "no role $u"
      printf "ALTER ROLE \"%s\" PASSWORD '%s';\n" "$u" "$pw" | pg_q
      db="$(printf "select coalesce((select datname from pg_database where datname='%s'), '%s');\n" "$u" "$PG_DB" | pg_q)" ;;
    mysql|mariadb) my_user_exists "$u" "$U_ENGINE" || die "no user $u"
      printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$u" "$pw" | my_q "$U_ENGINE"; db="$u" ;;
  esac
  echo "# password rotated for $u ($U_ENGINE). Update the app's .env now; old password no longer works."
  print_creds "$U_ENGINE" "$db" "$u" "$pw"
}

# ---- guided upgrade -------------------------------------------------------------
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
validate_config() { # strict: refuse anything ambiguous before touching the server
  local bad=0 v p seen=" "
  err() { printf '!! config: %s\n' "$*" >&2; bad=1; }
  valid_ipv4 "${PRIVATE_IP:-}" || err "PRIVATE_IP '${PRIVATE_IP:-}' is not an IPv4 address"
  case "${PRIVATE_IP:-}" in 0.0.0.0) err "PRIVATE_IP must not be 0.0.0.0 (would publish on every interface)" ;; esac
  [ -z "${EXPECTED_PRIVATE_IP:-}" ] || valid_ipv4 "$EXPECTED_PRIVATE_IP" || err "EXPECTED_PRIVATE_IP is not an IPv4 address"
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
  echo "---- $(date '+%F %T %z') $TOOL_NAME $VERSION upgrade on $(hostname) (log: $DBM_LOG)"
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
render_to() { local DB_DIR="$1"; write_files >/dev/null; }
plan() { # renders the new files next to the old ones and prints a diff; returns 0 if anything changes
  log "Plan (dry run): what would change"
  PLAN_DIR="$(mktemp -d)"; chmod 700 "$PLAN_DIR"
  cp -p "$DB_DIR/.env" "$PLAN_DIR/.env"
  ( render_to "$PLAN_DIR" )
  local f changed=1
  for f in docker-compose.yml stack.env postgres/Dockerfile postgres/init/10-extensions.sql; do
    if ! diff -q "$DB_DIR/$f" "$PLAN_DIR/$f" >/dev/null 2>&1; then
      changed=0; echo "--- $f"; diff -u "$DB_DIR/$f" "$PLAN_DIR/$f" 2>/dev/null | tail -n +3 || true
    fi
  done
  [ "$changed" = 0 ] || echo "no file changes"
  return "$changed"
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

verify_backup() { # $1 dir: every enabled engine present, gzip ok, dump trailer present
  local d="$1"
  on "$ENABLE_POSTGRES" && { gzip -cd "$d/postgres.sql.gz" | tail -c 2000 | grep -q 'dump complete' || die "postgres dump in $d is incomplete"; }
  local e; for e in mysql mariadb; do
    if [ "$e" = mysql ]; then on "$ENABLE_MYSQL" || continue; else on "$ENABLE_MARIADB" || continue; fi
    [ -f "$d/$e.sql.gz" ] || die "$e dump missing in $d"
    if [ -n "$(gzip -cd "$d/$e.sql.gz" | head -c 1)" ]; then
      gzip -cd "$d/$e.sql.gz" | tail -c 500 | grep -q 'Dump completed' || die "$e dump in $d is incomplete"
    fi
  done
  echo "backup verified: $d"
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
    [ -z "$pimg" ] || docker tag "$pimg" "${PG_IMAGE%:*}:pre-upgrade" || warn "could not pin the current postgres image"
  fi
  installed_version > "$SAVE/version"
  chmod -R go-rwx "$SAVE"
  find "$DB_DIR/upgrade-saves" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +6 | while read -r old; do rm -rf "$old"; done
  find "$SAVE" -maxdepth 2 | sed 's/^/  /'
}

rollback() {
  log "ROLLBACK to $SAVE"
  cd "$DB_DIR"
  cp -p "$SAVE/docker-compose.yml" "$SAVE/.env" ./
  [ -f "$SAVE/stack.env" ] && cp -p "$SAVE/stack.env" ./
  [ -d "$SAVE/postgres" ] && { rm -rf ./postgres; cp -Rp "$SAVE/postgres" ./postgres; }
  if on "$ENABLE_POSTGRES"; then # put the old locally built image back under its tag
    local old img; img="$(set -a; . ./stack.env; echo "$PG_IMAGE")"
    old="${img%:*}:pre-upgrade"; docker image inspect "$old" >/dev/null 2>&1 || old="$(awk '$1=="postgres"{print $2}' "$SAVE/images.txt")"
    [ -z "$old" ] || docker tag "$old" "$img" || warn "could not retag old postgres image"
  fi
  dc up -d --wait --wait-timeout 300 --remove-orphans || warn "containers did not all become healthy after rollback"
  [ -f "$SAVE/manager.sh" ] && ! cmp -s "$SAVE/manager.sh" "$SELF" && cp -p "$SAVE/manager.sh" "$SELF.rolled-back-from" 2>/dev/null || true
  set +e; ( set -e; cmd_verify ); local rc=$?; set -e
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
  [ "$dry" = 1 ] || start_log
  banner upgrade
  [ "$dry" = 1 ] || snapshot_policy_check
  preflight
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
  LAST_BACKUP="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)"
  verify_backup "$LAST_BACKUP"
  savepoint
  log "Apply"
  set +e
  ( set -e; write_files; start_stack; firewall ); local rc=$?
  if [ "$rc" = 0 ]; then ( set -e; cmd_verify; [ "${DBM_TEST_FAIL_VERIFY:-0}" != 1 ] || { echo "test hook: forced verify failure"; exit 1; } ); rc=$?; fi
  if [ "$rc" = 0 ]; then ( set -e; cmd_doctor ); rc=$?; fi
  set -e
  if [ "$rc" != 0 ]; then
    warn "apply/verify/doctor failed (exit $rc) - rolling back automatically"
    rollback || true
    die "UPGRADE FAILED and was rolled back. Log: $DBM_LOG  Savepoint: $SAVE  Backup: $LAST_BACKUP"
  fi
  log "UPGRADE OK: $cur -> $VERSION"
  echo "backup: $LAST_BACKUP"; echo "savepoint: $SAVE (manual rollback: see docs/reference/db-server.md#upgrade)"; echo "log: $DBM_LOG"
}

listen_addrs() { # $1 port -> space-separated listening addr:port, "" if none, "?" if no tool
  if command -v ss >/dev/null 2>&1; then { ss -Htln "sport = :$1" 2>/dev/null || true; } | awk '{print $4}' | tr '\n' ' '
  elif command -v lsof >/dev/null 2>&1; then { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR>1{print $9}' | sort -u | tr '\n' ' '
  else echo "?"; fi
}
cmd_doctor() { # read-only
  local bad=0 p l
  log "Exposure: DB ports must listen on $PRIVATE_IP only"
  for p in $(enabled_ports); do
    l="$(listen_addrs "$p")"
    if [ "$l" = "?" ]; then echo "  $p: unknown (no ss or lsof to check)"
    elif [ -z "$l" ]; then echo "  $p: not listening"
    elif echo "$l" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):'; then echo "  $p: PUBLIC ($l) - PROBLEM"; bad=1
    else echo "  $p: ok ($l)"; fi
  done
  echo "  (Docker-published ports bypass ufw; binding to the private IP is what keeps them off the internet.)"
  if on "$ENABLE_ADMINER"; then
    l="$(listen_addrs "$ADMINER_PORT")"
    if [ "$l" = "?" ]; then echo "  adminer $ADMINER_PORT: unknown (no ss or lsof to check)"
    elif [ -z "$l" ]; then echo "  adminer $ADMINER_PORT: not listening"
    elif echo "$l" | grep -qvE '^(127\.0\.0\.1:[0-9]+[[:space:]]*)+$'; then echo "  adminer $ADMINER_PORT: NOT loopback-only ($l) - PROBLEM"; bad=1
    else echo "  adminer $ADMINER_PORT: ok ($l, tunnel only)"; fi
  fi
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
# Optional Adminer web UI on 127.0.0.1 only (SSH tunnel)
ENABLE_ADMINER=$ENABLE_ADMINER
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
  on "$ENABLE_ADMINER"   && echo "Adminer ($ADMINER_IMAGE) : 127.0.0.1:$ADMINER_PORT only - tunnel: ssh -N -L 8081:127.0.0.1:$ADMINER_PORT <user>@<db-public-ip>"
  echo "Root passwords are in $DB_DIR/.env (chmod 600) - not printed."
  echo
  cmd_env
  echo
  echo "Then redeploy the web app (Laravel caches config at deploy time)."
}

cmd_install() {
  need_root; banner install; validate_config; ensure_docker
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
    --non-interactive) NONINTERACTIVE=1 ;;
    --config) skip_next=1 ;;
    --version) echo "$TOOL_NAME $VERSION"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD="${1:-help}"; shift || true
detect_ip
case "$CMD" in help|-h|--help|init) ;; *) check_engines; guard_host; need_ip ;; esac
case "$CMD" in # mutating commands: one at a time
  upgrade|apply|install|reset|restore|backup|uninstall|create-db|create-user|grant|drop-db|drop-user|rotate-password)
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
