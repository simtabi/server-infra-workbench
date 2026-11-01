# Example: Next.js (SSR) as a daemon behind Nginx

Made up: site `www.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), Postgres + PgBouncer on DB droplet
`db-01` (`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `web`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:**

- **`output: "standalone"` and `node .next/standalone/server.js`.** The build traces which files the server
  imports and copies only those. The daemon runs plain Node, not `next start` or a full `node_modules`. Next
  leaves `public/` and `.next/static` out of the standalone folder on purpose, so the deploy copies them in.
- **A Ploi daemon (Supervisor) on `127.0.0.1:3000`.** `HOSTNAME=127.0.0.1` makes `server.js` bind loopback only.
  Nginx keeps TLS and serves `/_next/static` (content-hashed, cached for a year). `proxy_buffering off`
  lets streamed React Server Components through as they render.
- **No PM2.** Supervisor already restarts the process and keeps its log. PM2 would be a second process manager
  fighting the first.
- **Database access only on the server, without a password in any URL.** `new Pool()` reads `PG*` and the
  600 pgpass file from [`app-env.sh`](../_shared/app-env.sh). `import "server-only"` makes the build fail if a
  client component imports the pool. Anything prefixed `NEXT_PUBLIC_` is inlined into the JavaScript sent to
  browsers, so never put a DB setting there.

```bash
examples/run.sh node-nextjs       # validate (offline): profile, plan, app-env self-test
bin/workbench configure --profile dev-budget --client <you> --set APP=web \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env   # DB server; copy to web, remove
# web server: shared helpers once (examples/_shared/README.md), then as ploi:
vsw-app-env --stack nextjs --from ~/stg-db.env --out /home/ploi/www.example.com-shared
shred -u ~/stg-db.env
bin/workbench ploi daemon-create <server-id> --directory /home/ploi/www.example.com --dry-run \
  --command "/usr/local/bin/vsw-with-env /home/ploi/www.example.com-shared/.env node .next/standalone/server.js"
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh node-nextjs`: settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (placeholders) |
| [`next.config.ts`](next.config.ts) | standalone output, no `X-Powered-By`, compression left to Nginx |
| [`db.ts`](db.ts) | the server-only `pg` pool from `PG*` + `PGPASSFILE` |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): `npm ci`, build, copy static, migrate |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: restart, wait for `/api/health` |
| [`nginx-site.conf`](nginx-site.conf) | `/_next/static` from disk, the rest to `server.js`, unbuffered |

Checklist:

- [ ] an `app/api/health/route.ts` that returns 200 (and `SELECT 1` through the pool if you want DB in it)
- [ ] the Ploi site's web directory is the repo root, not `/public` (Next serves `public/` itself)
- [ ] a 2 GB droplet: `next build` peaks above 1 GB, so keep swap on (`bin/workbench server init` sets it)

Lesson: Prisma and some ORMs want a `DATABASE_URL` with the password inside. If you use one, build the URL at
runtime from `PG*` plus the pgpass file in a small wrapper, and never write it into `.env`. The password would
show up in `ps e` output and crash reports.
