# Example: Laravel with Horizon and Reverb

Made up: app `app.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), DB droplet `db-01` (`10.0.0.5`),
VPC `10.0.0.0/20`, environment `prd` of app `shop`. Profile
[`production-single`](../../config/profiles/production-single.conf): PITR, off-site copies, TLS to the DB,
alerts.

**Why:**

- **Horizon on Redis, on the web node.** Horizon needs Redis, so the queue lives in Redis next to PHP
  (Ploi installs it, bound to `127.0.0.1`), not in the DB droplet's Postgres. Jobs don't add load to the
  database the site depends on. A queue in Redis is only as durable as Redis, so `prd` jobs must be safe to
  retry (see the lesson). Horizon gives you a supervisor per queue, auto-balancing and a dashboard.
- **Reverb behind the same Nginx, on the same domain.** `location ~ ^/apps?/` proxies the websocket upgrade to
  `127.0.0.1:8080`. The site's certificate covers it, the DO firewall stays at 80/443, and browsers connect
  to `wss://app.example.com`. A separate `ws.` subdomain only adds a certificate and CORS.
- **Reverb keys generated on the server.** `REVERB_APP_SECRET` signs every broadcast. It's created with
  `openssl rand` by [`app-env.sh --stack none`](../_shared/app-env.sh) in the shared `.env` (600), never
  committed and never typed. `php artisan reverb:install` would write them too, but into the release's files.
- **Restarts after activation.** `horizon:terminate` and `reverb:restart` run in Ploi's post-deploy section,
  after the `current` symlink moved. That way Supervisor restarts both on the new code, not the old.
- **One scheduler daemon (`schedule:work`)** and no Ploi cron. Horizon's `horizon:snapshot` runs from the
  scheduler (`Schedule::command('horizon:snapshot')->everyFiveMinutes()`), which fills the dashboard's graphs.

```bash
examples/run.sh laravel-horizon-reverb      # validate (offline): profile checks, plans, app-env self-test
bin/siwo configure --profile production-single --client <you> --set APP=shop --set ALERT_EMAIL=<you@example.com> \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20 --set OFFSITE_BUCKET=<bucket>
bin/siwo env init --host web-01 --env prd --site app.example.com --from ~/prd-db.env --url https://app.example.com
# web server, as ploi (helpers: examples/_shared/README.md): the Reverb keys, once; later runs keep them
siw-app-env --stack none --out /home/ploi/app.example.com-shared \
  --generate REVERB_APP_ID --generate REVERB_APP_KEY --generate REVERB_APP_SECRET
bin/siwo ploi daemon-create <server-id> --directory /home/ploi/app.example.com --command "php artisan horizon" --dry-run
bin/siwo ploi daemon-create <server-id> --directory /home/ploi/app.example.com --command "php artisan reverb:start" --dry-run
bin/siwo ploi daemon-create <server-id> --directory /home/ploi/app.example.com --command "php artisan schedule:work" --dry-run
```

| Daemon | Command | Processes | Why |
|---|---|---|---|
| Horizon | `php artisan horizon` | 1 | Horizon forks its own workers (`config/horizon.php`); more daemons would duplicate them |
| Reverb | `php artisan reverb:start` | 1 | binds `REVERB_SERVER_HOST:REVERB_SERVER_PORT` (`127.0.0.1:8080`) |
| Scheduler | `php artisan schedule:work` | 1 | always exactly one, and no `schedule:run` cron ([daemons](../../docs/recipes/run-daemons.md)) |

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh laravel-horizon-reverb`: settings through `configure --dry-run`, plans, app-env self-test |
| [`app.env.example`](app.env.example) | the queue, Redis and Reverb keys (secrets empty here) |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): defaults for a new `.env`, the keys a deploy needs |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: `horizon:terminate`, `reverb:restart` |
| [`nginx-reverb.conf`](nginx-reverb.conf) | websocket + publish API proxy to the Reverb daemon |

Checklist:

- [ ] `redis-cli -h 127.0.0.1 ping` works, and `ss -ltn` shows Redis and Reverb on `127.0.0.1` only
- [ ] `/horizon` gated by `viewHorizon` in `HorizonServiceProvider` (only your admins)
- [ ] Redis `maxmemory-policy noeviction` (an evicted job is a lost job)
- [ ] Reverb's open-file limit: Ploi daemons inherit Supervisor's (`minfds`). Raise it before you expect thousands of sockets

Lesson: with `QUEUE_CONNECTION=redis`, a Redis restart without persistence drops the queued jobs. Turn on
`appendonly yes` in Redis, or keep a `database` queue for the jobs that must never be lost.
