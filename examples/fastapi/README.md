# Example: FastAPI + Uvicorn on Postgres

Made up: API `api.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), Postgres + PgBouncer on DB droplet
`db-01` (`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `api`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:**

- **`fastapi run` with `WEB_CONCURRENCY` workers, not Gunicorn + Uvicorn workers.** Uvicorn has its own process manager now. It
  restarts dead workers, and the FastAPI docs recommend it. That's one process tree less to understand.
  `--proxy-headers --forwarded-allow-ips 127.0.0.1` trusts `X-Forwarded-*` from Nginx only.
- **Loopback `127.0.0.1:8000` behind Ploi's Nginx.** TLS, HTTP/2 and slow clients stay in Nginx.
  `proxy_buffering off` lets `StreamingResponse` and SSE through as they are produced.
- **An empty conninfo.** psycopg 3 builds the connection from the `PG*` variables and reads the password from
  `PGPASSFILE` (600, written by [`app-env.sh`](../_shared/app-env.sh)). There is no `DATABASE_URL` with a password
  that could end up in a traceback or in `/docs`.
- **One small pool per worker, opened in `lifespan`.** A worker that can't reach the DB fails at start
  (Supervisor shows it) instead of on the first request. `max_size × workers` stays well under Postgres'
  `max_connections`, and PgBouncer on 6432 is there when it doesn't.
- **`/docs` off in production.** The OpenAPI UI lists every route to anyone.

```bash
examples/run.sh fastapi           # validate (offline): profile, plan, app-env self-test
bin/workbench configure --profile dev-budget --client <you> --set APP=api \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env   # DB server; copy to web, remove
# web server: shared helpers once (examples/_shared/README.md), then as ploi:
vsw-app-env --stack fastapi --from ~/stg-db.env --out /home/ploi/api.example.com-shared --set WEB_CONCURRENCY=3
shred -u ~/stg-db.env
bin/workbench ploi daemon-create <server-id> --directory /home/ploi/api.example.com --dry-run \
  --command "/usr/local/bin/vsw-with-env /home/ploi/api.example.com-shared/.env .venv/bin/fastapi run app/main.py --host 127.0.0.1 --port 8000 --proxy-headers --forwarded-allow-ips 127.0.0.1"
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh fastapi`: settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (placeholders) |
| [`db.py`](db.py) | the pool from `PG*` + `PGPASSFILE`, opened in `lifespan`, and a `/healthz` that checks it |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): venv per release, `alembic upgrade head` |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: restart, wait for `/healthz` |
| [`nginx-site.conf`](nginx-site.conf) | proxy to Uvicorn, unbuffered for streaming |

Checklist:

- [ ] workers = 2 × vCPU at most on a 2 GB droplet (each worker is a full Python process)
- [ ] `ss -ltn` shows `127.0.0.1:8000` only
- [ ] Alembic's `env.py` builds the URL without a password (`postgresql+psycopg://`); libpq fills the rest from `PG*`

Lesson: async code still blocks a worker if it calls a sync driver or does CPU work in a route. Use `async def`
with psycopg's async API, and plain `def` (FastAPI runs those in a thread pool) for anything blocking.
