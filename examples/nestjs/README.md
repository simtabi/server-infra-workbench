# Example: a NestJS API on Postgres

Made up: API `api.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), Postgres + PgBouncer on DB droplet
`db-01` (`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `api`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:**

- **The Fastify adapter.** It has lower overhead per request than Express, and `trustProxy: "127.0.0.1"`
  believes `X-Forwarded-*` from the local Nginx only. That keeps `req.ip` and rate limits honest.
- **A Ploi daemon on `127.0.0.1:3001`** (3000 is the Next.js example's port, so both can share a server).
  `enableShutdownHooks()` drains on SIGTERM and closes the DB pool. Supervisor restarts the process.
- **TypeORM without a password.** The `pg` driver reads the password from `PGPASSFILE` (600, written by
  [`app-env.sh`](../_shared/app-env.sh)). The config only says where to connect. `synchronize: false`
  means schema changes happen only through migrations, which the deploy runs before the new release goes live.
- **`npm prune --omit=dev` after the build.** The release keeps only production modules: less disk per release
  (Ploi keeps three), and no build tools in the running app's tree.

```bash
examples/run.sh nestjs            # validate (offline): profile, plan, app-env self-test
bin/workbench configure --profile dev-budget --client <you> --set APP=api \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env   # DB server; copy to web, remove
# web server: shared helpers once (examples/_shared/README.md), then as ploi:
vsw-app-env --stack nestjs --from ~/stg-db.env --out /home/ploi/api.example.com-shared
shred -u ~/stg-db.env
bin/workbench ploi daemon-create <server-id> --directory /home/ploi/api.example.com --dry-run \
  --command "/usr/local/bin/vsw-with-env /home/ploi/api.example.com-shared/.env node dist/main.js"
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh nestjs`: settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (placeholders) |
| [`main.ts`](main.ts) | Fastify adapter, loopback bind, trusted proxy, shutdown hooks |
| [`db.module.ts`](db.module.ts) | TypeORM from `PG*`, password from `PGPASSFILE`, no `synchronize` |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): build, prune, migrations |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: restart, wait for `/health` |
| [`nginx-site.conf`](nginx-site.conf) | proxy to the API, body size limit |

Checklist:

- [ ] a `/health` route (`@nestjs/terminus` with a TypeORM ping is the usual one)
- [ ] `dist/data-source.js` exports the same options for the migration CLI
- [ ] `ss -ltn` shows `127.0.0.1:3001` only

Lesson: TypeORM's `synchronize: true` is a convenience in development. In production it can drop a column
when an entity changes. Keep it off everywhere except a throwaway local database.
