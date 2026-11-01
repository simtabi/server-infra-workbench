# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh: the SAME block on web-01 and web-02 (app.example.com).
SITE_DOMAIN="app.example.com"
PRESET="laravel"
APP_ENV_NAME="production"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN="8.3.0"
NODE_MIN_MAJOR=22
REQUIRED_VARS="APP_URL DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD REDIS_HOST REDIS_PASSWORD AWS_BUCKET"
ENV_DEFAULTS="SESSION_DRIVER=redis CACHE_STORE=redis QUEUE_CONNECTION=redis FILESYSTEM_DISK=s3"
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
# --isolated takes a lock in the shared cache: if both nodes deploy at once, only one migrates
MIGRATE_CMD='php artisan migrate --force --isolated'
EXTRA_MIGRATE_CMDS=""
# the default build, plus the commit this release runs, for rolling-deploy.sh to wait on (GET /version)
BUILD_CMDS='composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
npm ci && npm run build
git rev-parse HEAD > REVISION'
POST_DEPLOY_CMDS=""
# this node, not the load balancer: a deploy on web-02 must not pass because web-01 answers
HEALTHCHECK_CMD='curl -fsS -o /dev/null -H "Host: app.example.com" http://127.0.0.1/up'
