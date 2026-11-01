# Ploi (`workbench ploi`)

**Why:** the app servers are provisioned and deployed with Ploi. The workbench drives the Ploi REST API
(`https://ploi.io/api`) for servers, sites, deploys and deploy scripts, daemons (queue workers), cron jobs,
databases and Let's Encrypt certificates, so a rollout can be scripted and every change is planned and audited.
The zero-downtime deploy script itself is [`src/shell/deploy/ploi-deploy.sh`](../tools/deploy-script.md).

## Least-privilege token

Create an API key in Ploi (Profile → API keys) and tick only the scopes you need; each endpoint has its own
scope. Store it as `PLOI_API_TOKEN`.

| Commands | Scopes |
| --- | --- |
| `servers`, `server`, `sites`, `site`, `deploy-script`, `daemons`, `crons`, `databases`, `certs` (and the live test) | Read servers, Read sites, Read daemons, Read cronjobs, Read databases, Read certificates |
| `deploy`, `deploy-script-set`, `site-create` | Create sites (deploy / update) |
| `daemon-create`, `cron-create`, `database-create`, `cert-create`, `server-restart` | the matching Create scope |
| `site-delete`, `daemon-delete`, `cron-delete`, `database-delete`, `cert-delete` | the matching Delete scope |

Leave the server and site **delete** scopes off unless you need them: Ploi's own advice, and it turns a mistake
into a 403.

## Commands

All take `--json`; writes take `--dry-run`, `--yes`; destructive writes need `--force`.

- `bin/workbench ploi servers`, `bin/workbench ploi server <server-id>`
- `bin/workbench ploi sites <server-id>`, `bin/workbench ploi site <server-id> <site-id>`
- `bin/workbench ploi site-create <server-id> app.example.com --web-directory /public --project-type laravel --user ploi`
- `bin/workbench ploi site-delete <server-id> <site-id> --force`
- `bin/workbench ploi deploy <server-id> <site-id>`
- `bin/workbench ploi deploy-script <server-id> <site-id>`, `bin/workbench ploi deploy-script-set <server-id> <site-id> --file deploy.sh` (no-op if identical)
- `bin/workbench ploi daemons <server-id>`,
  `bin/workbench ploi daemon-create <server-id> --command "php artisan queue:work" --user ploi --processes 2 --directory /home/ploi/app.example.com`,
  `bin/workbench ploi daemon-delete <server-id> <daemon-id> --force`
- `bin/workbench ploi crons <server-id>`,
  `bin/workbench ploi cron-create <server-id> --command "php /home/ploi/app.example.com/artisan schedule:run" --frequency "* * * * *" --user ploi`,
  `bin/workbench ploi cron-delete <server-id> <cron-id> --force`
- `bin/workbench ploi databases <server-id>`
- `bin/workbench ploi database-create <server-id> app --user app --out ~/.config/vps-server-workbench/app-db.pass --site <site-id>`
  generates the password locally, writes it to the file (mode 600) and shows it as `***` in the plan; without
  `--user` only the database is created.
- `bin/workbench ploi database-delete <server-id> <database-id> --force`
- `bin/workbench ploi certs <server-id> <site-id>`,
  `bin/workbench ploi cert-create <server-id> <site-id> --domain app.example.com,www.app.example.com`,
  `bin/workbench ploi cert-delete <server-id> <site-id> <cert-id> --force`
- `bin/workbench ploi server-restart <server-id> --force` (downtime)

## Checklist

- [ ] API key has read scopes plus only the create scopes you use; no server/site delete scope by default.
- [ ] DNS for the site points at the server (check with `bin/workbench cf dns list <zone> --name app`) before
      `cert-create`.
- [ ] Queue workers are daemons, not cron loops; the schedule is one `* * * * *` cron per site.
- [ ] The deploy script in Ploi matches the repo's (`deploy-script` vs your file; `deploy-script-set` is a no-op
      when they match).
- [ ] Database passwords live only in the `--out` file and the site's `.env`.

## Lessons learned

- **Let's Encrypt needs DNS first.** Ploi asks Let's Encrypt to validate over HTTP; if the record still points
  elsewhere (or is proxied with a redirect loop) the request fails and repeated attempts hit Let's Encrypt's rate
  limits. Point DNS, wait for it to resolve, then `cert-create`.
- **Generated passwords never touch argv or the API log.** They are created locally, written to the `--out`
  file before the request, and redacted in plans and `--verbose` output.
- **Deploys are asynchronous.** `deploy` queues the script and returns; watch the result in Ploi or with the site
  status, not by re-running the command.
- **Ploi's own `force` flag** on certificate requests maps to the workbench's `--force`; it is only sent when
  you pass it.
