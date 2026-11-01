# Shared pieces of the examples

Not an example (no `example.conf`, so `examples/run.sh --all` skips it): the files several examples use, kept
once here so a fix lands everywhere.

| File | Used by | What |
|---|---|---|
| [`app-env.sh`](app-env.sh) | symfony, django, fastapi, rails, go-api, node-nextjs, nestjs, wordpress; `--stack none` in laravel-horizon-reverb | turns the DB manager's `DB_*` block into the stack's own settings in the shared `.env`; generates the stack's secret once. `--stack none --generate K --set K=V`: only app keys, no DB block (a Laravel `.env` from `env init` already has it) |
| [`with-env.sh`](with-env.sh) | the Ploi daemons of the non-PHP examples | runs a command with the `.env` exported (Supervisor has no env file); no `eval` |
| [`reload-daemon.sh`](reload-daemon.sh) | Ploi's post-deploy section of the daemon examples | restart each app port after the release went live, wait until it is healthy |
| [`nginx-proxy.conf`](nginx-proxy.conf) | every example with an app server behind Nginx | keepalive, `X-Forwarded-*`, timeouts; included, not copied |
| [`ploi-script.sh`](ploi-script.sh) | every example with a `ploi-deploy.settings.sh` | prints [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh) with the SETTINGS block replaced by the example's settings: one script to paste into Ploi, settings kept per example. `--check` (run by `run.sh`): syntax, required settings, no unknown names |

## Install on a web server (once)

```bash
scp examples/_shared/*.sh examples/_shared/nginx-proxy.conf web-01:/tmp/siw/
ssh -t web-01 'cd /tmp/siw && sudo install -m 755 app-env.sh /usr/local/bin/siw-app-env \
  && sudo install -m 755 with-env.sh /usr/local/bin/siw-with-env \
  && sudo install -m 755 reload-daemon.sh /usr/local/bin/siw-reload-daemon \
  && sudo install -m 644 nginx-proxy.conf /etc/nginx/snippets/siw-proxy.conf && sudo nginx -t && rm -rf /tmp/siw'
```

**Why restart after activation (`reload-daemon.sh`):** on a zero-downtime Ploi site the deploy script runs in the
new release *before* Ploi points the site at it. A daemon restarted there would come back on the old code. Ploi's
post-deploy section runs after the switch. A daemon is found by the port it listens on (`ss`), never by a name
pattern, so it can't signal the wrong process.

## The DB settings

**Why `app-env.sh`:** `bin/siwo env init` writes a *Laravel* `.env`. Other stacks name things differently
(`DATABASE_URL`, `PGHOST`, `DB_NAME`), and the usual habit is a URL with the password in it. That shape leaks:
it ends up in logs, error pages, `ps` output and crash reports. So for Postgres stacks the password goes into a
pgpass file (mode 600) that libpq and the drivers built on it read by themselves (psycopg, node-postgres, pgx,
the `pg` gem, `pdo_pgsql`). The `.env` only holds where to connect.

```bash
# on the DB server: the env's block into a 600 file, then copy it to the web server and remove it
sudo /root/docker-db-server-manager.sh env-creds stg --out /root/stg-db.env
# on the web server, as ploi (dry run first: key names only, values never printed)
bash app-env.sh --stack django --from ~/stg-db.env --out /home/ploi/api.example.com-shared --dry-run
bash app-env.sh --stack django --from ~/stg-db.env --out /home/ploi/api.example.com-shared
shred -u ~/stg-db.env
bash app-env.sh --list        # what each stack gets
bash app-env.sh --self-test   # offline, throwaway files (examples/run.sh runs it per example)
```

Rules the script keeps: values are never printed; files are written 600 through a temp file; keys you added to
the `.env` are kept (the previous file is `.env.bak`, 600); a generated secret is never replaced, because
rotating it logs everyone out (and for WordPress salts, invalidates every cookie).
