# Deploy script (Ploi, native PHP)

[`scripts/deploy/ploi-deploy.sh`](../scripts/deploy/ploi-deploy.sh) is a
zero-downtime deploy script for a Laravel app. Paste it into **Ploi > Site >
Deploy script** after editing its `SETTINGS` block (example:
[`examples/myapp/ploi-deploy.settings.sh`](../examples/myapp/ploi-deploy.settings.sh)).

## What it does

0. **Preflight**: git, php (>= `PHP_MIN`), composer, node (>= `NODE_MIN_MAJOR`), npm.
1. **Shared folders**: creates `/home/ploi/<site>-shared/storage` on the first run.
2. **Shared `.env`**: adopts an existing `<site>/<APP_SUBDIR>/.env`, or creates
   one from `.env.example`, then stops with a list of required keys that are
   still empty (`APP_URL TENANCY_CENTRAL_DOMAINS DB_HOST DB_PORT DB_DATABASE
   DB_USERNAME DB_PASSWORD`). Fill them (see
   [web-server-ploi.md](web-server-ploi.md#update-db_-settings)) and deploy again.
3. Symlinks `storage` and `.env` into the release.
4. `composer install --no-dev`, `npm ci`, `npm run build`.
5. **First run** (no `storage/installed`): runs `INSTALL_COMMAND`; with
   `INSTALL_NEEDS_ADMIN=1` it first asks for `ADMIN_NAME/EMAIL/PASSWORD` in
   `<shared>/install.env` (deleted with `shred` afterwards). Later runs:
   `migrate --force`, plus `tenants:migrate --force` when `TENANTS_MIGRATE=1`.
6. `storage:link`, `config/route/view/event:cache`, `queue:restart`, then the
   optional `DOCTOR_COMMAND`.

Do not also enable Ploi's `schedule:run` cron when the scheduler runs as a
daemon ([daemons.md](daemons.md)).

## Ploi placeholder caveat

Ploi substitutes its placeholders (`{RELEASE}`, `{BRANCH}`, `{SITE}`, ...) in
the deploy script text **before** bash runs it. A shell variable written as
`${BRANCH}` therefore becomes `$main`, and with `set -u` the deploy dies with
`main: unbound variable`. The script uses non-placeholder names
(`DEPLOY_BRANCH`, `SITE_DOMAIN`) and only uses `{RELEASE}` on purpose
(`cd {RELEASE}`). Keep it that way when editing.
