# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a Symfony app at shop.example.com (zero-downtime site).
SITE_DOMAIN="shop.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN="8.4.0"
NODE_MIN_MAJOR=""
REQUIRED_VARS="DATABASE_URL APP_SECRET"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
# dump-env compiles .env into .env.local.php (no parsing per request); it holds no password to leak
BUILD_CMDS='composer install --no-dev --optimize-autoloader --classmap-authoritative --no-interaction --prefer-dist
composer dump-env prod
php bin/console cache:clear --no-warmup
php bin/console cache:warmup
php bin/console asset-map:compile'
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
MIGRATE_CMD='php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration'
EXTRA_MIGRATE_CMDS='php bin/console messenger:setup-transports --no-interaction'
POST_DEPLOY_CMDS=""                   # FPM reload + worker stop go in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://shop.example.com/'
