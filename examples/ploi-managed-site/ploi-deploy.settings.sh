# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for an existing plain-PHP site at legacy.example.com.
# Works as-is on an in-place site and after you switch the site to zero-downtime in Ploi.
SITE_DOMAIN="legacy.example.com"
PRESET="generic"                      # no framework steps; only what is set below
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN="8.2.0"                       # the deploy stops with a clear message on an older CLI PHP
NODE_MIN_MAJOR=""
# the keys the app reads from .env; an empty one stops the deploy before anything changes
REQUIRED_VARS="APP_URL DB_HOST DB_NAME DB_USER"
ENV_DEFAULTS=""                       # the existing .env is adopted on the first run, values kept
BUILD_CMDS=""                         # default: composer install when composer.json exists
FIRST_INSTALL_CMD=":"                 # nothing to install: the site already runs
INSTALL_ENV_KEYS=""
MIGRATE_CMD=""                        # this app has no migrations; set e.g. 'php bin/migrate.php' if it does
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://legacy.example.com/health.php'
