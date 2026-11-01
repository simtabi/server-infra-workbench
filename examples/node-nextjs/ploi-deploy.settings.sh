# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a Next.js app at www.example.com (zero-downtime site).
SITE_DOMAIN="www.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN=""                            # not a PHP app
NODE_MIN_MAJOR=22
REQUIRED_VARS="PGHOST PGDATABASE PGUSER PGPASSFILE PORT"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
# standalone output needs public/ and .next/static copied next to server.js (Next leaves them out on purpose)
BUILD_CMDS='npm ci --no-audit --no-fund
npm run build
cp -R public .next/standalone/ 2>/dev/null || true
cp -R .next/static .next/standalone/.next/'
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
MIGRATE_CMD='/usr/local/bin/siw-with-env .env npx --no-install drizzle-kit migrate'   # or prisma/knex/node-pg-migrate
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""                   # restarts go in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://www.example.com/api/health'
