# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a Django app at api.example.com (zero-downtime site).
SITE_DOMAIN="api.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN=""                            # not a PHP app
NODE_MIN_MAJOR=""
REQUIRED_VARS="PGHOST PGDATABASE PGUSER PGPASSFILE DJANGO_SECRET_KEY DJANGO_ALLOWED_HOSTS"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
# a venv per release: the old release keeps running on its own packages until the switch
BUILD_CMDS='python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt
/usr/local/bin/vsw-with-env .env .venv/bin/python manage.py collectstatic --noinput
/usr/local/bin/vsw-with-env .env .venv/bin/python manage.py check --deploy --fail-level WARNING'
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
MIGRATE_CMD='/usr/local/bin/vsw-with-env .env .venv/bin/python manage.py migrate --noinput'
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""                   # restarts go in Ploi's post-deploy script (post-deploy.sh): after activation
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://api.example.com/healthz'
