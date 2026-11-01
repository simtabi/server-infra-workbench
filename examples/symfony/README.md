# Example: Symfony on Postgres

Made up: shop `shop.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), Postgres + PgBouncer on DB droplet
`db-01` (`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `shop`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:**

- **`DATABASE_URL` without a password.** Doctrine wants a URL, and the usual one, with the password between
  the user and the host, puts the password into the profiler, `debug:container --env-vars`, logs
  and exception pages. Here the URL stops at the user. `pdo_pgsql` is libpq, and libpq reads the password from
  `~/.pgpass` of the user PHP-FPM runs as (`ploi`, mode 600). [`app-env.sh`](../_shared/app-env.sh) writes both.
  The default pgpass path matters: FPM doesn't pass `PGPASSFILE` through to PHP.
- **`serverVersion=18` in the URL.** That's the DB manager's Postgres. Doctrine then skips a version probe and
  generates SQL for the right platform.
- **`composer dump-env prod`.** It compiles the `.env` into `.env.local.php`, so nothing is parsed per request.
  It holds no secret beyond `APP_SECRET`, because the password isn't in it.
- **Messenger on the Doctrine transport.** It uses the same database, so there's nothing extra to run on a
  2 GB box. The worker is a Ploi daemon (`messenger:consume --time-limit=3600`). `messenger:stop-workers`
  in the post-deploy section makes it restart on the new release.
- **PHP-FPM reload after activation.** OPcache keys on the resolved path. Ploi's `{RELOAD_PHP_FPM}` placeholder,
  as the first line of the post-deploy section, reloads FPM once the `current` symlink has moved.

```bash
examples/run.sh symfony           # validate (offline): profile, plan, app-env self-test
bin/workbench configure --profile dev-budget --client <you> --set APP=shop \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env   # DB server; copy to web, remove
# web server: shared helpers once (examples/_shared/README.md), then as ploi (the pgpass goes to ~/.pgpass):
vsw-app-env --stack symfony --from ~/stg-db.env --out /home/ploi/shop.example.com-shared \
  --set MESSENGER_TRANSPORT_DSN=doctrine://default?auto_setup=0
shred -u ~/stg-db.env
bin/workbench ploi daemon-create <server-id> --directory /home/ploi/shop.example.com --dry-run \
  --command "php bin/console messenger:consume async --time-limit=3600 --memory-limit=128M"
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh symfony`: settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (placeholders) |
| [`doctrine.yaml`](doctrine.yaml) | DBAL from `DATABASE_URL`, server version, prod caches |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): composer, `dump-env`, cache, assets, migrations |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: reload FPM, stop the Messenger workers |

Checklist:

- [ ] Ploi site type Symfony (web directory `/public`); no Nginx change needed
- [ ] `ls -l ~ploi/.pgpass` is `-rw-------`, owned by `ploi` (libpq ignores a group- or world-readable one)
- [ ] `php bin/console dbal:run-sql 'select 1'` works as `ploi` on the server

Lesson: two sites on one server under the same `ploi` user share `~/.pgpass`. That's fine: each line is keyed
by host, port, database and user, and `app-env.sh` replaces only its own line. But a site running as its own
system user needs its own home and its own pgpass.
