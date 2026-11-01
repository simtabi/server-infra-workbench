# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a Rails 8 app at shop.example.com (zero-downtime site).
SITE_DOMAIN="shop.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN=""                            # not a PHP app
NODE_MIN_MAJOR=""
REQUIRED_VARS="PGHOST PGDATABASE PGUSER PGPASSFILE SECRET_KEY_BASE"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
# gems in vendor/bundle per release; assets compiled with a dummy key (no secret needed to build)
BUILD_CMDS='bundle config set --local deployment true
bundle config set --local without "development test"
bundle install --jobs 4 --quiet
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile'
FIRST_INSTALL_CMD='/usr/local/bin/siw-with-env .env bin/rails db:prepare'
INSTALL_ENV_KEYS=""
MIGRATE_CMD='/usr/local/bin/siw-with-env .env bin/rails db:migrate'
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""                   # restarts go in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://shop.example.com/up'
