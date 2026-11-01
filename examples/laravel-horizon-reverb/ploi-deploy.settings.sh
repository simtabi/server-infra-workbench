# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh: Laravel + Horizon + Reverb at app.example.com (zero-downtime).
SITE_DOMAIN="app.example.com"
PRESET="laravel"
STAGE="main"                          # zero-downtime: paste again as the post-deploy script, STAGE="post"
APP_ENV_NAME="production"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN="8.3.0"
NODE_MIN_MAJOR=22
# the laravel default list, plus what Horizon and Reverb can't start without
REQUIRED_VARS="APP_URL DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD REDIS_HOST REVERB_APP_ID REVERB_APP_KEY REVERB_APP_SECRET"
ENV_DEFAULTS="QUEUE_CONNECTION=redis CACHE_STORE=redis REDIS_HOST=127.0.0.1 BROADCAST_CONNECTION=reverb REVERB_HOST=@SITE_DOMAIN@ REVERB_PORT=443 REVERB_SCHEME=https REVERB_SERVER_HOST=127.0.0.1 REVERB_SERVER_PORT=8080"
FIRST_INSTALL_CMD=""                  # "" = MIGRATE_CMD
INSTALL_ENV_KEYS=""
MIGRATE_CMD=""                        # laravel default: php artisan migrate --force
EXTRA_MIGRATE_CMDS=""
BUILD_CMDS=""                         # default: composer install + npm ci/build (Echo gets the VITE_REVERB_* values)
POST_DEPLOY_CMDS=""                   # Horizon/Reverb restarts go in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://app.example.com/up'
