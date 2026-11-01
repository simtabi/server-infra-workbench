# shellcheck shell=bash disable=SC2034
# SETTINGS block of src/shell/deploy/ploi-deploy.sh for a Go API at api.example.com (zero-downtime site).
SITE_DOMAIN="api.example.com"
PRESET="generic"
DEPLOY_BRANCH="main"
APP_SUBDIR="."
PHP_MIN=""                            # not a PHP app
NODE_MIN_MAJOR=""
REQUIRED_VARS="PGHOST PGDATABASE PGUSER PGPASSFILE LISTEN_ADDR"
ENV_DEFAULTS=""                       # app-env.sh writes the .env before the first deploy
# a static binary per release (CGO off), built and vetted before the release goes live
BUILD_CMDS='export CGO_ENABLED=0
go vet ./...
go build -trimpath -ldflags "-s -w" -o bin/api ./cmd/api'
FIRST_INSTALL_CMD=""
INSTALL_ENV_KEYS=""
MIGRATE_CMD='/usr/local/bin/vsw-with-env .env bin/api migrate'   # or goose/migrate/atlas, reading PG* the same way
EXTRA_MIGRATE_CMDS=""
POST_DEPLOY_CMDS=""                   # restarts go in Ploi's post-deploy section (post-deploy.sh)
HEALTHCHECK_CMD='curl -fsS -o /dev/null https://api.example.com/healthz'
