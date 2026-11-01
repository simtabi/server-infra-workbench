# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a FastAPI app at api.example.com (zero-downtime site).
SITE_DOMAIN="api.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN=""                            # not a PHP app
NODE_MIN_MAJOR=""
REQUIRED_VARS="PGHOST PGDATABASE PGUSER PGPASSFILE SECRET_KEY"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
BUILD_CMDS='python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt'
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
MIGRATE_CMD='/usr/local/bin/vsw-with-env .env .venv/bin/alembic upgrade head'
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""                   # restarts go in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://api.example.com/healthz'
