# Deploy script (Ploi, native PHP)

[`shell/deploy/ploi-deploy.sh`](../../shell/deploy/ploi-deploy.sh) is a deploy
script for any PHP and/or Node app on a native (non-Docker) Ploi server. Edit
its `SETTINGS` block and paste it into the site's deploy script in Ploi.

- **Presets:** `PRESET=laravel` adds the Laravel steps (required `.env` keys,
  shared `storage/`, `key:generate`, `migrate --force`, `optimize`,
  `queue:restart`, `storage:link`). `PRESET=generic` runs only what you configure.
- **Site type:** works on zero-downtime sites (`{RELEASE}`) and on plain in-place
  sites; it detects which one it's on.
- **Hooks:** every project-specific step is an optional hook, empty by default.

Examples: [generic Laravel](../../examples/generic-laravel/ploi-deploy.settings.sh),
and a multi-tenant app with an admin install command (see [examples/](../../examples/README.md)).

## Contents

- [Pipeline](#pipeline)
- [Settings](#settings)
- [Hooks](#hooks)
- [First run](#first-run)
- [Ploi placeholder caveat](#ploi-placeholder-caveat)

## Pipeline

```mermaid
flowchart TD
    start(["Ploi starts a deploy"]) --> rel{"{RELEASE} filled in?"}
    rel -->|"yes: zero-downtime"| zd["cd release"]
    rel -->|"no: in-place site"| ip["cd SITE_ROOT, git pull DEPLOY_BRANCH"]
    zd --> sub["cd APP_SUBDIR"]
    ip --> sub
    sub --> pre["1. Preflight: git, php >= PHP_MIN, composer / node / npm<br/>when composer.json / package.json exist"]
    pre -->|"missing / too old"| stop1["stop with a fix-it message"]
    pre --> envq{"2. shared .env exists?"}
    envq -->|"no, old .env found"| adopt["adopt it"]
    envq -->|no| create["create from .env.example + ENV_DEFAULTS"]
    envq -->|yes| req
    adopt --> req
    create --> req{"REQUIRED_VARS all set?"}
    req -->|no| stop2["stop: list the empty keys"]
    req -->|yes| link["link .env (+ storage for laravel), chmod 600,<br/>SITE_ROOT/.env -> shared for Ploi's editor"]
    link --> build["3. BUILD_CMDS or composer install + npm ci/build"]
    build --> inst{"4. first-install marker exists?"}
    inst -->|"no"| keys{"INSTALL_ENV_KEYS set?"}
    keys -->|"yes, install.env empty"| stop3["stop: fill install.env"]
    keys -->|"filled / not needed"| install["FIRST_INSTALL_CMD (or MIGRATE_CMD)<br/>write marker, shred install.env"]
    inst -->|yes| migrate["MIGRATE_CMD"]
    install --> extra["EXTRA_MIGRATE_CMDS"]
    migrate --> extra
    extra --> cache["5. laravel: optimize, storage:link, queue:restart<br/>POST_DEPLOY_CMDS, HEALTHCHECK_CMD"]
    cache --> done(["deployed"])
```

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `SITE_DOMAIN` | `example.com` | Ploi site domain; also the folder name in `/home/ploi` |
| `PRESET` | `laravel` | `laravel` or `generic` |
| `APP_ENV_NAME` | `production` | `APP_ENV` written into a new shared `.env` (laravel) |
| `DEPLOY_BRANCH` | `main` | branch pulled on in-place sites |
| `APP_SUBDIR` | `.` | app root inside the repository, e.g. `src` |
| `PHP_MIN` / `NODE_MIN_MAJOR` | `8.3.0` / empty | preflight minimums; empty = don't check the version |
| `REQUIRED_VARS` | laravel: `APP_URL DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD`; generic: none | keys that must be non-empty before the deploy continues |
| `ENV_DEFAULTS` | empty | `KEY=VALUE` pairs written into a **new** shared `.env`; `@SITE_DOMAIN@` is replaced |
| `SITE_ROOT`, `SHARED`, `OLD_ENV` | `/home/ploi/<site>`, `<SITE_ROOT>-shared`, `<SITE_ROOT>/<APP_SUBDIR>/.env` | can be overridden from the environment |

## Hooks

All are shell snippets run with `bash -euo pipefail -c` in the app root; multi-line is fine.

| Hook | Runs | Default |
|---|---|---|
| `BUILD_CMDS` | every deploy | `composer install --no-dev` if `composer.json`, `npm ci && npm run build` if `package.json` |
| `FIRST_INSTALL_CMD` | once, until `<shared>/.first-install-done` exists | `MIGRATE_CMD` |
| `INSTALL_ENV_KEYS` | with the first install | empty. Keys read from `<shared>/install.env` and exported to `FIRST_INSTALL_CMD`; the file is `shred`-deleted afterwards |
| `MIGRATE_CMD` | every later deploy | laravel: `php artisan migrate --force`; generic: none |
| `EXTRA_MIGRATE_CMDS` | after the install or migrate, every deploy | empty (e.g. `php artisan tenants:migrate --force`) |
| `POST_DEPLOY_CMDS` | after the preset's caches and restarts | empty |
| `HEALTHCHECK_CMD` | last; a failure fails the deploy | empty (e.g. `curl -fsS -o /dev/null https://example.com/up`) |

On a Laravel site that already has `storage/installed` (from an older version of
this script), the first install counts as done.

## First run

The first deploy may stop, on purpose:

1. **Empty `.env` keys.** Fill the `DB_*` values with
   [`update-env-db.sh`](web-server-ploi.md#update-db_-settings) and the rest in
   Ploi's environment editor, then deploy again.
2. **Install inputs** (only with `INSTALL_ENV_KEYS`). Fill
   `/home/ploi/<site>-shared/install.env` (`KEY=value` lines, `chmod 600`) and
   deploy again.

The queue worker and scheduler run as Ploi daemons ([daemons.md](daemons.md));
`queue:restart` makes them load the new release. Don't also enable a
`schedule:run` cron. `make test` runs the script end to end against a scratch
repository ([`tests/shell/deploy-sandbox.sh`](../../tests/shell/deploy-sandbox.sh)).

## Ploi placeholder caveat

Ploi replaces its placeholders (`{RELEASE}`, `{BRANCH}`, `{SITE}` and others)
in the deploy script text **before** bash runs it, comments included. A shell
variable written as `${BRANCH}` therefore becomes `$main`, and with `set -u`
the deploy dies with `main: unbound variable`. The script only uses
`{RELEASE}`, on purpose (`cd {RELEASE}`), and names its own variables
`DEPLOY_BRANCH`, `SITE_DOMAIN` and so on. The smoke test
(`make test`) fails if a placeholder name is used as a shell variable.
