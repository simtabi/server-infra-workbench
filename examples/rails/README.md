# Example: Rails 8 + Puma on Postgres

Made up: shop `shop.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), Postgres + PgBouncer on DB droplet
`db-01` (`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `shop`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:**

- **Puma on `127.0.0.1:3000` behind Ploi's Nginx**, with Nginx serving `public/assets` (fingerprinted, cached
  forever). Kamal and Thruster are Rails 8's Docker path. On a Ploi server, Nginx already does what Thruster
  would.
- **Solid Queue inside Puma (`SOLID_QUEUE_IN_PUMA=1`).** One daemon instead of two on a 2 GB box. Split it into
  its own daemon (`bin/jobs`) when jobs start to compete with requests.
- **One database per env.** Rails 8's default `production` config wants four databases (primary, cache, queue,
  cable). The DB manager gives each env one database and one least-privilege login. So keep Solid Cache, Queue
  and Cable in the primary: copy `db/queue_schema.rb`, `db/cache_schema.rb` and `db/cable_schema.rb` into a
  normal migration, and remove `connects_to` from `config/environments/production.rb`,
  `config/cache.yml` and `config/cable.yml`.
- **No password in `database.yml` or `DATABASE_URL`.** The `pg` gem is libpq, so the `PG*` variables and the 600
  pgpass file from [`app-env.sh`](../_shared/app-env.sh) are enough. `SECRET_KEY_BASE` is generated once on
  the server and replaces `config/master.key` for this one value. Assets build with `SECRET_KEY_BASE_DUMMY=1`,
  so the build never needs the real secret.

```bash
examples/run.sh rails             # validate (offline): profile, plan, app-env self-test
bin/workbench configure --profile dev-budget --client <you> --set APP=shop \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env   # DB server; copy to web, remove
# web server: shared helpers once (examples/_shared/README.md), then as ploi:
siw-app-env --stack rails --from ~/stg-db.env --out /home/ploi/shop.example.com-shared --set SOLID_QUEUE_IN_PUMA=1
shred -u ~/stg-db.env
bin/workbench ploi daemon-create <server-id> --directory /home/ploi/shop.example.com --dry-run \
  --command "/usr/local/bin/siw-with-env /home/ploi/shop.example.com-shared/.env bin/bundle exec puma -C config/puma.rb"
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh rails`: settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (placeholders) |
| [`database.yml`](database.yml) | production config with no host, user or password (libpq reads them) |
| [`puma.rb`](puma.rb) | loopback bind, workers/threads from the env, Solid Queue plugin |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): bundle, assets, `db:prepare` once, then `db:migrate` |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: restart Puma, wait for `/up` |
| [`nginx-site.conf`](nginx-site.conf) | assets from disk, everything else to Puma |

Checklist:

- [ ] `pool` ≥ Puma threads + Solid Queue threads (else `ActiveRecord::ConnectionTimeoutError` under load)
- [ ] `config.assume_ssl = true` and `config.force_ssl = true` (Nginx terminates TLS)
- [ ] the daemon runs `bundle exec puma -C config/puma.rb`, not `rails server` (its own `-b`/`-p` defaults can override the loopback bind)
- [ ] the Ruby version on the server matches `.ruby-version` (install it once with a version manager as ploi)

Lesson: `db:prepare` on a fresh database runs `schema.rb`, not the migrations. That's why the Solid
schemas have to be in a migration *and* in `schema.rb`, or the first install misses the queue tables.
