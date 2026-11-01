# Example: Laravel Octane (FrankenPHP) behind Nginx

Made up: app `app.example.com` on Ploi web droplet `web-01` (`10.0.0.6`, 4 GB), DB droplet `db-01` (`10.0.0.5`),
VPC `10.0.0.0/20`, environment `prd` of app `shop`. Profile
[`production-single`](../../config/profiles/production-single.conf) with `WEB_DROPLET_MB=4096`.

**Why:**

- **Octane only when boot time is the cost.** PHP-FPM boots Laravel on every request (often 20-40 ms). Octane
  boots it once per worker and keeps it in memory. That's the win, and also the risk: state you put in a
  static property or a singleton survives into the next user's request. Run the test suite with Octane before
  you switch, and check the packages you use support it.
- **4 GB web droplet.** Each worker holds a booted app (roughly 60-120 MB). `workers = CPUs` (2 on this size),
  plus Nginx, the queue daemon and the scheduler doesn't fit in 2 GB with headroom for a deploy, which runs
  `composer` and `npm` next to the live workers.
- **FrankenPHP, as a Ploi daemon on `127.0.0.1:8000`, Nginx in front.** Ploi keeps TLS, the certificate
  renewals and its Nginx config. Octane serves plain HTTP on loopback only. FrankenPHP is a single static
  binary, with no PECL extension to build (Swoole needs one) and no extra Go binary per release (RoadRunner
  needs one).
- **FrankenPHP has its own PHP.** The binary embeds its own PHP build, so it doesn't use Ploi's PHP version or
  extensions. `./frankenphp php-cli -m` must list `pdo_pgsql` (and `redis` if you use it). The deploy runs
  `./frankenphp version`, so a missing binary fails the deploy, not the first request.
- **A restart after activation, not `octane:reload`.** See [`post-deploy.sh`](post-deploy.sh). The server
  resolved its release directory when it started.
- **`--max-requests=500`** recycles a worker after 500 requests, so a slow leak can't grow forever.

```bash
examples/run.sh laravel-octane      # validate (offline): profile checks, plans, the assembled deploy script
bin/siwo configure --profile production-single --client <you> --set APP=shop --set ALERT_EMAIL=<you@example.com> \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20 \
  --set OFFSITE_BUCKET=<bucket> --set WEB_DROPLET_MB=4096
bin/siwo env init --host web-01 --env prd --site app.example.com --from ~/prd-db.env --url https://app.example.com
# web server, as ploi, once: the app requires laravel/octane; this downloads the FrankenPHP binary
cd /home/ploi/app.example.com && php artisan octane:install --server=frankenphp --no-interaction \
  && mv frankenphp /home/ploi/app.example.com-shared/frankenphp
bin/siwo ploi daemon-create <server-id> --directory /home/ploi/app.example.com --dry-run \
  --command "php artisan octane:start --server=frankenphp --host=127.0.0.1 --port=8000 --workers=2 --max-requests=500"
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh laravel-octane`: settings through `configure --dry-run`, plans |
| [`app.env.example`](app.env.example) | the Octane keys and why the direct DB port |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): the build links the shared FrankenPHP binary |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: restart Octane on the new release, wait for `/up` |
| [`nginx-site.conf`](nginx-site.conf) | static files from `public/`, the rest to Octane |

Checklist:

- [ ] `php artisan octane:status` is running, and `ss -ltn` shows `127.0.0.1:8000` (never `0.0.0.0`)
- [ ] the DB role's connection limit is at least workers + queue workers + 2
- [ ] no request data in singletons or static properties, and the test suite passes against `octane:start` locally
- [ ] Ploi's PHP-FPM pool for the site can be scaled down: Nginx no longer sends PHP to it

Lesson: the first symptom of shared state under Octane is one user seeing another user's data (a locale, a
tenant, a cached `auth()->user()`). It never shows up on a single-user test. Load-test with two users before
`prd`.
