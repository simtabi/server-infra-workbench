# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a NestJS API at api.example.com (zero-downtime site).
SITE_DOMAIN="api.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN=""                            # not a PHP app
NODE_MIN_MAJOR=22
REQUIRED_VARS="PGHOST PGDATABASE PGUSER PGPASSFILE PORT"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
# build with dev dependencies, then drop them: the daemon runs dist/ with production modules only
BUILD_CMDS='npm ci --no-audit --no-fund
npm run build
npm prune --omit=dev'
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
MIGRATE_CMD='/usr/local/bin/siw-with-env .env node node_modules/typeorm/cli.js migration:run -d dist/data-source.js'
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""                   # restarts go in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://api.example.com/health'
