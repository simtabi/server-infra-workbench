# shellcheck shell=bash disable=SC2034
# SETTINGS block for a plain Laravel app at app.example.com (zero-downtime Ploi site).
SITE_DOMAIN="app.example.com"
PRESET="laravel"
APP_ENV_NAME="production"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN="8.3.0"
NODE_MIN_MAJOR=22
REQUIRED_VARS=""                      # laravel default: APP_URL + DB_*
ENV_DEFAULTS="QUEUE_CONNECTION=database CACHE_STORE=database"
FIRST_INSTALL_CMD='php artisan migrate --force --seed'
INSTALL_ENV_KEYS=""
MIGRATE_CMD=""                        # laravel default: php artisan migrate --force
EXTRA_MIGRATE_CMDS=""
BUILD_CMDS=""                         # default: composer install + npm ci/build
POST_DEPLOY_CMDS=""
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://app.example.com/up'
