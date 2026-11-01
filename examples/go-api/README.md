# Example: a Go API on Postgres (systemd unit)

Made up: API `api.example.com` on Ploi web droplet `web-01` (`10.0.0.6`), Postgres + PgBouncer on DB droplet
`db-01` (`10.0.0.5`), VPC `10.0.0.0/20`, environment `stg` of app `api`. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:**

- **systemd, not a Ploi daemon.** A single static binary is what systemd is built for. You get journald logs
  (`journalctl -u api-example`), `Restart=always`, a memory cap, and a sandbox. The [unit](api-example.service)
  makes the file system read-only (`ProtectSystem=strict`, `ProtectHome=read-only`), drops every capability and
  filters syscalls to `@system-service`. A bug in the API can't write to the box. Check the score with
  `systemd-analyze security api-example`.
- **Loopback `127.0.0.1:8080` behind Ploi's Nginx**, which keeps TLS and the certificate renewals.
- **`pgxpool.New(ctx, "")`.** pgx reads the same `PG*` variables and `PGPASSFILE` as libpq. The password lives
  only in the 600 pgpass file from [`app-env.sh`](../_shared/app-env.sh). It is never in the unit, `ps` output or
  a `DATABASE_URL`. `EnvironmentFile=` loads the rest of the shared `.env`.
- **Graceful stop.** `srv.Shutdown` finishes in-flight requests on SIGTERM. After a deploy,
  [`vsw-reload-daemon`](../_shared/reload-daemon.sh) sends TERM as `ploi` and systemd starts the new binary.
  `ploi` needs no sudo rule.
- **Build on the server, per release.** `CGO_ENABLED=0 go build -trimpath` gives a static binary, and the old
  release keeps running until Ploi switches. To build in CI instead, have `BUILD_CMDS` download the artifact.

```bash
examples/run.sh go-api            # validate (offline): profile, app-env self-test
bin/workbench configure --profile dev-budget --client <you> --set APP=api \
  --set DB_PRIVATE_IP=10.0.0.5 --set WEB_PRIVATE_IP=10.0.0.6 --set VPC_CIDR=10.0.0.0/20
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env   # DB server; copy to web, remove
# web server: shared helpers once (examples/_shared/README.md), then as ploi:
vsw-app-env --stack go --from ~/stg-db.env --out /home/ploi/api.example.com-shared
shred -u ~/stg-db.env
# first deploy in Ploi (builds bin/api), then as root:
install -m 644 api-example.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now api-example
systemd-analyze security api-example     # aim for "OK" or better
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh go-api`: settings through `configure --dry-run`, plus the app-env self-test |
| [`app.env.example`](app.env.example) | what the shared `.env` holds (placeholders) |
| [`main.go`](main.go) | env config, pgx pool from `PG*`, `/healthz`, graceful shutdown |
| [`api-example.service`](api-example.service) | the hardened systemd unit |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | SETTINGS for [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh): `go vet`, static build, migrate |
| [`post-deploy.sh`](post-deploy.sh) | Ploi's post-deploy section: TERM, wait for `/healthz` from the new binary |
| [`nginx-site.conf`](nginx-site.conf) | proxy to the API |

Checklist:

- [ ] Go installed on the web server for the `ploi` user (or `BUILD_CMDS` downloads a CI artifact)
- [ ] `systemctl status api-example` active; `ss -ltn` shows `127.0.0.1:8080` only
- [ ] `MemoryMax` fits next to Nginx and PHP-FPM if the server hosts other sites

Lesson: `ExecStart` points into `/home/ploi/api.example.com`, which is a symlink on a zero-downtime site. systemd
resolves it each time it starts the service, so a restart is all it takes to pick up the new release. Never
copy the binary to `/usr/local/bin`: you'd lose rollback.
