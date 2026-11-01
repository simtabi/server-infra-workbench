# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh: Laravel Octane (FrankenPHP) at app.example.com (zero-downtime).
SITE_DOMAIN="app.example.com"
PRESET="laravel"
STAGE="main"                          # zero-downtime: paste again as the post-deploy script, STAGE="post"
APP_ENV_NAME="production"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN="8.3.0"                       # the CLI PHP for composer/artisan; FrankenPHP brings its own (README)
NODE_MIN_MAJOR=22
REQUIRED_VARS=""                      # laravel default
ENV_DEFAULTS="OCTANE_SERVER=frankenphp OCTANE_HTTPS=false"
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
MIGRATE_CMD=""                        # laravel default: php artisan migrate --force
EXTRA_MIGRATE_CMDS=""
# the default build, plus the one FrankenPHP binary kept in the shared folder (downloaded once, README), linked
# into each release where Octane looks for it; a release without it would fail its first request, not here
BUILD_CMDS='composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
npm ci && npm run build
ln -sfn /home/ploi/app.example.com-shared/frankenphp frankenphp
./frankenphp version'
POST_DEPLOY_CMDS=""                   # the Octane restart goes in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://app.example.com/up'
