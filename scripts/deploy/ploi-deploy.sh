#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# Ploi zero-downtime deploy script for a Laravel app (native PHP, no Docker).
# Paste this into Ploi > Site > Deploy script and edit the SETTINGS block.
#
# !! Ploi substitutes its placeholders (RELEASE, BRANCH, SITE ... written in
# !! curly braces) in this text BEFORE bash runs it - comments included. A shell
# !! variable written as dollar + brace + a placeholder name gets rewritten too,
# !! and bash then fails with e.g. "main: unbound variable". So variables here
# !! use non-placeholder names (DEPLOY_BRANCH, SITE_DOMAIN). See docs/deploy.md.
#
# First run bootstraps everything it can and stops with clear instructions
# for anything only a human can fill in. Later runs just deploy.
# Queue worker (queue:work) and scheduler (schedule:work) run as Ploi daemons
# from /home/ploi/<site>/<APP_SUBDIR>; do NOT also enable Ploi's schedule:run cron.
# queue:restart below makes the worker pick up each new release.
# ----------------------------------------------------------------------------
# ---- SETTINGS ----------------------------------------------------------------
SITE_DOMAIN="example.com"                 # Ploi site domain (= folder in /home/ploi)
APP_ENV_NAME="production"                 # APP_ENV written on first run
DEPLOY_BRANCH="main"
APP_SUBDIR="src"                          # Laravel root inside the repo ("." if top level)
PHP_MIN="8.5.0"
NODE_MIN_MAJOR=22
# First-install command (runs once, until storage/installed exists). Leave empty
# to just run migrations. ADMIN_* values are read from <shared>/install.env and
# passed as --admin-name/--admin-email/--admin-password when INSTALL_NEEDS_ADMIN=1.
INSTALL_COMMAND="php artisan migrate --force"
INSTALL_NEEDS_ADMIN=0
TENANTS_MIGRATE=0                         # 1 = also run tenants:migrate (stancl/tenancy)
DOCTOR_COMMAND=""                         # optional health check, e.g. php artisan app:doctor
# ------------------------------------------------------------------------------
SHARED="${SHARED:-/home/ploi/$SITE_DOMAIN-shared}"     # survives every release
OLD_ENV="${OLD_ENV:-/home/ploi/$SITE_DOMAIN/$APP_SUBDIR/.env}"  # picked up if you already made one
REQUIRED_VARS="APP_URL TENANCY_CENTRAL_DOMAINS DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD"

say()  { echo "==> $*"; }
stop() { echo; echo "!! $*"; exit 1; }
env_get() { grep -E "^$1=" "$2" | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }
env_set() { # env_set KEY VALUE FILE  (replace or append)
  if grep -qE "^$1=" "$3"; then sed -i "s|^$1=.*|$1=$2|" "$3"; else echo "$1=$2" >> "$3"; fi
}

# 0. Preflight: tools this deploy needs on the host ---------------------------
need() { command -v "$1" >/dev/null 2>&1 || stop "$1 is not installed on this server. $2"; }
need git      "Install git."
need php      "Install PHP $PHP_MIN+ and set it as the CLI default."
need composer "Install Composer."
need node     "Install Node $NODE_MIN_MAJOR."
need npm      "npm ships with Node; reinstall Node."
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
php -r "exit(version_compare(PHP_VERSION, '$PHP_MIN', '>=') ? 0 : 1);" \
  || stop "PHP $PHP_VER found, but this app needs PHP $PHP_MIN+. Switch the server and site PHP version in Ploi."
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge "$NODE_MIN_MAJOR" ] || stop "Node $NODE_MAJOR found, but this app needs Node $NODE_MIN_MAJOR+."
say "Using PHP $PHP_VER, Node $(node -v), $(composer --version 2>/dev/null | head -1)"

# shellcheck disable=SC1083  # {RELEASE} is replaced by Ploi before running
cd {RELEASE}
git pull origin "$DEPLOY_BRANCH"
cd "$APP_SUBDIR"

# 1. Shared folders ----------------------------------------------------------
mkdir -p "$SHARED"
if [ ! -d "$SHARED/storage" ]; then
  say "First run: creating shared storage"
  cp -a storage "$SHARED/storage"
fi
mkdir -p "$SHARED"/storage/{app/public,framework/{cache/data,sessions,views},logs,keys}

# 2. Shared .env -------------------------------------------------------------
if [ ! -f "$SHARED/.env" ]; then
  if [ -f "$OLD_ENV" ]; then
    say "Adopting existing $OLD_ENV"
    cp "$OLD_ENV" "$SHARED/.env"
  else
    say "First run: creating $SHARED/.env from .env.example"
    cp .env.example "$SHARED/.env"
    env_set APP_ENV   "$APP_ENV_NAME"     "$SHARED/.env"
    env_set APP_DEBUG false               "$SHARED/.env"
    env_set APP_URL   "https://$SITE_DOMAIN"   "$SHARED/.env"
    env_set TENANCY_CENTRAL_DOMAINS "$SITE_DOMAIN" "$SHARED/.env"
    env_set SESSION_SECURE_COOKIE true    "$SHARED/.env"
    env_set DB_PASSWORD ""                "$SHARED/.env"
  fi
  chmod 600 "$SHARED/.env"
fi

missing=""
for v in $REQUIRED_VARS; do [ -n "$(env_get "$v" "$SHARED/.env" || true)" ] || missing="$missing $v"; done
[ -z "$missing" ] || stop "Fill in these values in $SHARED/.env, then deploy again:$missing
   Edit it with:  nano $SHARED/.env   (leave APP_KEY empty - the installer sets it)"

# 3. Link shared files into this release -------------------------------------
rm -rf storage .env
ln -s "$SHARED/storage" storage
ln -s "$SHARED/.env"    .env

# 4. Dependencies and assets (every deploy) ----------------------------------
say "Installing PHP dependencies"
composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
say "Building frontend"
npm ci --no-audit --no-fund
npm run build

# 5. First install, or a normal migrate --------------------------------------
if [ ! -f storage/installed ]; then
  INSTALL_ENV="$SHARED/install.env"
  if [ "$INSTALL_NEEDS_ADMIN" = 1 ]; then
    if [ ! -f "$INSTALL_ENV" ]; then
      printf 'ADMIN_NAME=\nADMIN_EMAIL=\nADMIN_PASSWORD=\n' > "$INSTALL_ENV"; chmod 600 "$INSTALL_ENV"
    fi
    ADMIN_NAME=$(env_get ADMIN_NAME "$INSTALL_ENV" || true)
    ADMIN_EMAIL=$(env_get ADMIN_EMAIL "$INSTALL_ENV" || true)
    ADMIN_PASSWORD=$(env_get ADMIN_PASSWORD "$INSTALL_ENV" || true)
    if [ -z "$ADMIN_NAME" ] || [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_PASSWORD" ]; then
      stop "First install needs an administrator. Fill in $INSTALL_ENV, then deploy again.
     Edit it with:  nano $INSTALL_ENV   (it is deleted after a successful install)"
    fi
  fi

  say "First run: $INSTALL_COMMAND"
  if [ "$INSTALL_NEEDS_ADMIN" = 1 ]; then
    # shellcheck disable=SC2086  # INSTALL_COMMAND is a command line on purpose
    $INSTALL_COMMAND --no-interaction \
      --admin-name="$ADMIN_NAME" --admin-email="$ADMIN_EMAIL" --admin-password="$ADMIN_PASSWORD"
    shred -u "$INSTALL_ENV" 2>/dev/null || rm -f "$INSTALL_ENV"
  else
    # shellcheck disable=SC2086
    $INSTALL_COMMAND
  fi
  if [ "$TENANTS_MIGRATE" = 1 ]; then php artisan tenants:migrate --force; fi
  touch storage/installed   # no-op if the install command already wrote it
else
  say "Running migrations"
  php artisan migrate --force
  if [ "$TENANTS_MIGRATE" = 1 ]; then php artisan tenants:migrate --force; fi
fi

# 6. Caches, workers, health check -------------------------------------------
php artisan storage:link --force >/dev/null 2>&1 || true
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan event:cache
php artisan queue:restart
# shellcheck disable=SC2086
if [ -n "$DOCTOR_COMMAND" ]; then $DOCTOR_COMMAND; fi

echo "Application deployed"
