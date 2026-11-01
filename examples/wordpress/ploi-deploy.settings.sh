# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a Bedrock WordPress at blog.example.com (zero-downtime).
SITE_DOMAIN="blog.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN="8.3.0"
NODE_MIN_MAJOR=""
REQUIRED_VARS="DB_NAME DB_USER DB_PASSWORD DB_HOST WP_HOME AUTH_KEY NONCE_SALT"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
# uploads live in the shared folder so every release sees the same media library
BUILD_CMDS='composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
mkdir -p /home/ploi/blog.example.com-shared/uploads
rm -rf web/app/uploads && ln -sfn /home/ploi/blog.example.com-shared/uploads web/app/uploads'
FIRST_INSTALL_CMD='wp core is-installed || echo "open https://blog.example.com/wp/wp-admin/install.php once to create the admin user"'
INSTALL_ENV_KEYS=""
MIGRATE_CMD='wp core update-db'
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""                   # FPM reload goes in Ploi's post-deploy section (README)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://blog.example.com/'
