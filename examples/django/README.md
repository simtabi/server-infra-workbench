# Example: Django + Gunicorn on Postgres

Made up: API `api.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), Postgres + PgBouncer on DB droplet
`db-01` (`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `api`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:** the DB server does not care what the app is written in. The only Django-specific parts are the web
tier and how the app finds its database. The choices:

- **Gunicorn on `127.0.0.1:8000`, Nginx in front.** Ploi already runs Nginx with TLS. Gunicorn only listens on
  loopback, so it is never reachable from outside, and Nginx serves `/static/` itself.
- **Gunicorn as a Ploi daemon** (Supervisor). Supervisor restarts it if it crashes. `max_requests` recycles
  workers so a slow memory leak can't fill a 2 GB box.
- **No password in settings, `.env` or any URL.** [`app-env.sh`](../_shared/app-env.sh) writes `PG*` settings
  and puts the password in a 600 pgpass file. psycopg reads it through `OPTIONS.passfile`. Django's error
  pages and `DATABASE_URL`-style logs can't show what isn't there.
- **`CONN_MAX_AGE=60` + `CONN_HEALTH_CHECKS`.** A new Postgres connection per request costs a TCP and auth
  round trip across the VPC. A broken connection is caught before it's used. PgBouncer (port 6432) is the next
  step when you add workers.
- **A venv per release, and a restart after activation.** The old release keeps its packages until Ploi
  switches the symlink. Ploi's post-deploy section then restarts Gunicorn, so it loads the new code.

```bash
examples/run.sh django            # validate (offline): profile, plan, app-env self-test
bin/siwo configure --profile dev-budget --client <you> --set APP=api \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
# DB server: the stg block into a 600 file; copy it to the web server, then remove it there
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env
# web server: the shared helpers once (examples/_shared/README.md), then as ploi the .env + .pgpass
siw-app-env --stack django --from ~/stg-db.env --out /home/ploi/api.example.com-shared \
  --set DJANGO_ALLOWED_HOSTS=api.example.com --set DJANGO_SETTINGS_MODULE=config.settings.production
shred -u ~/stg-db.env
bin/siwo ploi daemon-create <server-id> --directory /home/ploi/api.example.com --dry-run \
  --command "/usr/local/bin/siw-with-env /home/ploi/api.example.com-shared/.env .venv/bin/gunicorn -c gunicorn.conf.py config.wsgi"
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh django`: the settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (placeholders; the password is only in `.pgpass`) |
| [`settings_production.py`](settings_production.py) | `DATABASES` with `passfile`, secure cookies, proxy header, logging to stdout |
| [`gunicorn.conf.py`](gunicorn.conf.py) | loopback bind, worker count, recycling, trusted proxy |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh) (`PRESET=generic`): venv, collectstatic, `check --deploy`, migrate |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: restart Gunicorn, wait for `/healthz` |
| [`nginx-site.conf`](nginx-site.conf) | upstream, `/static/`, proxy to Gunicorn |

Checklist:

- [ ] `manage.py check --deploy` passes (the deploy runs it and stops on a warning)
- [ ] a `/healthz` view that returns 200 without touching sessions
- [ ] `ss -ltn` on the web server shows `127.0.0.1:8000`, never `0.0.0.0:8000`
- [ ] the DB block file is shredded on both servers

Lesson: one Gunicorn daemon restarts with a gap of a second or two (Nginx answers 502 meanwhile). Run a second
daemon with `PORT=8001` and the second `server` line in the upstream. `siw-reload-daemon 8000 /healthz 8001
/healthz` restarts one at a time, and the site stays up.
