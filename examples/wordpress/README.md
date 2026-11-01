# Example: WordPress on MySQL (Bedrock)

Made up: blog `blog.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), MySQL only on DB droplet `db-01`
(`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `blog`. Profile
[`mysql-app`](../../config/profiles/mysql-app.conf).

**Why:**

- **The `mysql-app` profile.** WordPress speaks MySQL only, so Postgres and PgBouncer stay off and their RAM
  goes to the InnoDB buffer pool. Backups, off-site copies, per-env databases and least-privilege logins are the
  same as for any other app.
- **Bedrock instead of a stock `wp-config.php`.** WordPress core, plugins and themes are Composer
  dependencies, pinned in `composer.lock` and deployed like code. The config reads a `.env`, which fits the
  shared `.env` that [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh) links into each release.
  `DISALLOW_FILE_MODS` turns off installs and updates from wp-admin, so the server never drifts from the
  repository, and a hijacked admin account can't upload a plugin.
- **Generated salts, never replaced.** [`app-env.sh`](../_shared/app-env.sh) writes the DB block as Bedrock's
  `DB_*` (mysqli has no password file, so `DB_PASSWORD` sits in the 600 `.env`). It generates the eight salts with
  `openssl rand` on the first run. A later run keeps them, because new salts log every user out.
- **Real cron, not WP-Cron.** `DISABLE_WP_CRON=true` stops page views from triggering jobs. A Ploi cron runs
  `wp cron event run --due-now` every 5 minutes, so jobs run on time even with no traffic.
- **Uploads in the shared folder**, symlinked into each release. A deploy never loses the media library, and
  off-site copies of `/home/ploi/blog.example.com-shared/uploads` belong in the backup plan.

```bash
examples/run.sh wordpress         # validate (offline): profile, app-env self-test
bin/workbench configure --profile mysql-app --client <you> --set APP=blog --set ALERT_EMAIL=<you@example.com> \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
sudo /root/docker-db-server-manager.sh env-creds stg mysql --out /root/stg-db.env   # DB server; copy, remove
# web server: shared helpers once (examples/_shared/README.md), then as ploi:
vsw-app-env --stack wordpress --from ~/stg-db.env --out /home/ploi/blog.example.com-shared \
  --set WP_HOME=https://blog.example.com --set WP_SITEURL=https://blog.example.com/wp
shred -u ~/stg-db.env
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh wordpress`: settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (secrets empty here, filled on the server) |
| [`production.php`](production.php) | Bedrock's production config: no file mods, no debug output, bounded revisions |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for the deploy script: composer, shared uploads, `wp core update-db` |

Checklist:

- [ ] Ploi site with web directory `/web` (Bedrock's document root), PHP 8.3+, WP-CLI on the server
- [ ] Ploi's `{RELOAD_PHP_FPM}` placeholder as the post-deploy section (OPcache picks up the new release)
- [ ] Ploi cron, every 5 minutes, as ploi: `cd /home/ploi/blog.example.com && wp cron event run --due-now`
- [ ] the admin user created once at `/wp/wp-admin/install.php`, with a password from your password manager

Lesson: `DB_HOST` for WordPress is `host:port` in one value (`10.0.0.5:3306`). `app-env.sh` joins the DB block's
host and port for you, because a missing port quietly connects to 3306, which is wrong for the MariaDB engine
on 3307.
