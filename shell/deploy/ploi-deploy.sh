#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# Ploi deploy script for a PHP/Node app on a native (non-Docker) Ploi server.
# Paste it into the site's deploy script in Ploi and edit the SETTINGS block.
# Works for zero-downtime sites and for plain in-place sites (auto-detected).
#
# PRESET=laravel adds Laravel defaults (required .env keys, migrate, key:generate,
# optimize, queue:restart). PRESET=generic does only what you configure.
# Every project-specific step is an optional hook, empty by default.
#
# !! Ploi substitutes its placeholders (RELEASE, BRANCH, SITE ... written in
# !! curly braces) in this text BEFORE bash runs it - comments included. A shell
# !! variable written as dollar + brace + a placeholder name gets rewritten too,
# !! and bash then fails with e.g. "main: unbound variable". So variables here
# !! use non-placeholder names (DEPLOY_BRANCH, SITE_DOMAIN). See docs/tools/deploy-script.md.
#
# The first run bootstraps what it can and stops with clear instructions for
# anything only a human can fill in. Later runs just deploy.
# ----------------------------------------------------------------------------

# ---- SETTINGS ----------------------------------------------------------------
SITE_DOMAIN="example.com"          # Ploi site domain (= folder in /home/ploi)
PRESET="laravel"                   # laravel | generic
APP_ENV_NAME="production"          # APP_ENV written into a new .env (laravel)
DEPLOY_BRANCH="main"
APP_SUBDIR="."                     # app root inside the repo, e.g. "src"
PHP_MIN="8.3.0"                    # preflight minimum; "" = don't check PHP
NODE_MIN_MAJOR=""                  # e.g. 22; "" = check only that node exists if package.json does
# Keys that must be non-empty in the shared .env ("" = preset default).
REQUIRED_VARS=""
# KEY=VALUE pairs (no spaces) written into a NEW shared .env only. @SITE_DOMAIN@ is replaced.
ENV_DEFAULTS=""
# Hooks: shell snippets run with bash -euo pipefail in the app root. Multi-line ok.
FIRST_INSTALL_CMD=""               # once, until the install marker exists ("" = MIGRATE_CMD)
INSTALL_ENV_KEYS=""                # e.g. "ADMIN_EMAIL ADMIN_PASSWORD": read from <shared>/install.env,
                                   # exported to FIRST_INSTALL_CMD, file shredded afterwards
MIGRATE_CMD=""                     # every later deploy ("" = preset default)
EXTRA_MIGRATE_CMDS=""              # after MIGRATE_CMD / FIRST_INSTALL_CMD, every deploy
BUILD_CMDS=""                      # "" = composer install (composer.json) + npm ci/build (package.json)
POST_DEPLOY_CMDS=""                # after the preset's caches/restarts
HEALTHCHECK_CMD=""                 # last; a failure fails the deploy
# ------------------------------------------------------------------------------
SITE_ROOT="${SITE_ROOT:-/home/ploi/$SITE_DOMAIN}"
SHARED="${SHARED:-$SITE_ROOT-shared}"                    # survives every release
OLD_ENV="${OLD_ENV:-$SITE_ROOT/$APP_SUBDIR/.env}"        # adopted if no shared .env yet
MARKER="$SHARED/.first-install-done"

say()  { echo "==> $*"; }
stop() { echo; echo "!! $*"; exit 1; }
env_get() { grep -E "^$1=" "$2" | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }
env_set() { # env_set KEY VALUE FILE  (replace or append; GNU sed, as on Ubuntu)
  local v; v=$(printf '%s' "$2" | sed 's/[&|\\]/\\&/g')   # escape sed specials in the value
  if grep -qE "^$1=" "$3"; then sed -i "s|^$1=.*|$1=$v|" "$3"; else echo "$1=$2" >> "$3"; fi
}
hook() { [ -z "$2" ] || { say "$1"; bash -euo pipefail -c "$2"; }; }

case "$PRESET" in
  laravel)
    : "${REQUIRED_VARS:=APP_URL DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD}"
    : "${MIGRATE_CMD:=php artisan migrate --force}" ;;
  generic) ;;
  *) stop "PRESET must be laravel or generic (got $PRESET)" ;;
esac

# 0. Release directory: Ploi fills this in on zero-downtime sites ------------
# shellcheck disable=SC1083  # {RELEASE} is replaced by Ploi before running
RELEASE_DIR="{RELEASE}"
case "$RELEASE_DIR" in "{"*) RELEASE_DIR="$SITE_ROOT" ;; esac   # in-place site
[ -d "$RELEASE_DIR" ] || stop "release directory $RELEASE_DIR does not exist"
cd "$RELEASE_DIR"
git pull origin "$DEPLOY_BRANCH"
cd "$APP_SUBDIR" || stop "APP_SUBDIR=$APP_SUBDIR not found in the repository"
APP_ROOT="$(pwd)"

# 1. Preflight -----------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || stop "$1 is not installed on this server. $2"; }
need git "Install git."
if [ -n "$PHP_MIN" ] && { [ -f composer.json ] || [ "$PRESET" = laravel ]; }; then
  need php "Install PHP $PHP_MIN+ and set it as the CLI default."
  need composer "Install Composer."
  php -r "exit(version_compare(PHP_VERSION, '$PHP_MIN', '>=') ? 0 : 1);" \
    || stop "PHP $(php -r 'echo PHP_VERSION;') found, but this app needs PHP $PHP_MIN+. Switch the PHP version in Ploi."
fi
if [ -f package.json ] || [ -n "$NODE_MIN_MAJOR" ]; then
  need node "Install Node ${NODE_MIN_MAJOR:-LTS}."; need npm "npm ships with Node; reinstall Node."
  if [ -n "$NODE_MIN_MAJOR" ]; then
    NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
    [ "$NODE_MAJOR" -ge "$NODE_MIN_MAJOR" ] || stop "Node $NODE_MAJOR found, but this app needs Node $NODE_MIN_MAJOR+."
  fi
fi
say "Deploying $SITE_DOMAIN ($PRESET) from $APP_ROOT"

# 2. Shared .env (and storage for Laravel) -------------------------------------
mkdir -p "$SHARED"; chmod 700 "$SHARED"
if [ ! -f "$SHARED/.env" ]; then
  if [ -f "$OLD_ENV" ] && [ ! -L "$OLD_ENV" ]; then
    say "Adopting existing $OLD_ENV"; cp "$OLD_ENV" "$SHARED/.env"
  elif [ -f .env.example ]; then
    say "First run: creating $SHARED/.env from .env.example"
    cp .env.example "$SHARED/.env"
    if [ "$PRESET" = laravel ]; then
      env_set APP_ENV "$APP_ENV_NAME" "$SHARED/.env"
      env_set APP_DEBUG false "$SHARED/.env"
      env_set APP_URL "https://$SITE_DOMAIN" "$SHARED/.env"
      env_set SESSION_SECURE_COOKIE true "$SHARED/.env"
      env_set DB_PASSWORD "" "$SHARED/.env"
    fi
  else
    : > "$SHARED/.env"
  fi
  for kv in $ENV_DEFAULTS; do
    env_set "${kv%%=*}" "$(printf '%s' "${kv#*=}" | sed "s/@SITE_DOMAIN@/$SITE_DOMAIN/g")" "$SHARED/.env"
  done
fi
chmod 600 "$SHARED/.env"

missing=""
for v in $REQUIRED_VARS; do [ -n "$(env_get "$v" "$SHARED/.env" || true)" ] || missing="$missing $v"; done
[ -z "$missing" ] || stop "Fill in these values in $SHARED/.env, then deploy again:$missing
   Edit it with:  nano $SHARED/.env   (or shell/web/update-env-db.sh for DB_*)"

if [ "$PRESET" = laravel ]; then
  if [ ! -d "$SHARED/storage" ]; then
    say "First run: creating shared storage"
    if [ -d storage ] && [ ! -L storage ]; then cp -a storage "$SHARED/storage"; else mkdir -p "$SHARED/storage"; fi
  fi
  mkdir -p "$SHARED"/storage/{app/public,framework/{cache/data,sessions,views},logs}
  [ -L storage ] || rm -rf storage
  ln -sfn "$SHARED/storage" storage
  # an install made by older versions of this script (storage/installed) counts as done
  [ ! -f "$SHARED/storage/installed" ] || touch "$MARKER"
fi
[ -L .env ] || rm -f .env
ln -sfn "$SHARED/.env" .env
# Ploi's environment editor opens $SITE_ROOT/.env: point it at the shared file
if [ "$APP_ROOT" != "$SITE_ROOT" ] && { [ ! -e "$SITE_ROOT/.env" ] || [ -L "$SITE_ROOT/.env" ]; }; then
  ln -sfn "$SHARED/.env" "$SITE_ROOT/.env"
fi

# 3. Dependencies and assets -----------------------------------------------------
if [ -n "$BUILD_CMDS" ]; then
  hook "Build" "$BUILD_CMDS"
else
  if [ -f composer.json ]; then say "composer install"; composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist; fi
  if [ -f package.json ]; then
    say "npm ci + build"; npm ci --no-audit --no-fund
    if grep -q '"build"' package.json; then npm run build; fi
  fi
fi

# 4. First install, or migrations --------------------------------------------------
if [ "$PRESET" = laravel ] && [ -z "$(env_get APP_KEY "$SHARED/.env" || true)" ]; then
  say "Generating APP_KEY"; php artisan key:generate --force
fi
if [ ! -f "$MARKER" ]; then
  INSTALL_ENV="$SHARED/install.env"
  if [ -n "$INSTALL_ENV_KEYS" ]; then
    if [ ! -f "$INSTALL_ENV" ]; then
      (umask 077; for k in $INSTALL_ENV_KEYS; do echo "$k="; done > "$INSTALL_ENV")
    fi
    empty=""
    for k in $INSTALL_ENV_KEYS; do
      val="$(env_get "$k" "$INSTALL_ENV" || true)"; [ -n "$val" ] || empty="$empty $k"; export "$k=$val"
    done
    [ -z "$empty" ] || stop "First install needs:$empty. Fill them in $INSTALL_ENV, then deploy again.
   Edit it with:  nano $INSTALL_ENV   (it is deleted after a successful install)"
  fi
  hook "First install" "${FIRST_INSTALL_CMD:-$MIGRATE_CMD}"
  if [ -n "$INSTALL_ENV_KEYS" ]; then shred -u "$INSTALL_ENV" 2>/dev/null || rm -f "$INSTALL_ENV"; fi
  touch "$MARKER"
else
  hook "Migrations" "$MIGRATE_CMD"
fi
hook "Extra migrations" "$EXTRA_MIGRATE_CMDS"

# 5. Caches, workers, hooks, health check -------------------------------------------
if [ "$PRESET" = laravel ]; then
  php artisan storage:link --force >/dev/null 2>&1 || true
  php artisan optimize             # config, routes, views, events
  php artisan queue:restart        # daemons pick up the new code
fi
hook "Post-deploy" "$POST_DEPLOY_CMDS"
hook "Health check" "$HEALTHCHECK_CMD"

echo "Application deployed"
