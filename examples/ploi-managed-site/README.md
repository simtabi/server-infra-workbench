# Example: an existing Ploi site on the repo's deploy script

Made up: a plain-PHP site `legacy.example.com` that has run on Ploi web droplet `web-01` (`10.0.0.6`) for years
with a hand-edited deploy script, and a `.env` that someone once edited on the server. The DB droplet of profile
[`dev-budget`](../../config/profiles/dev-budget.conf) is unchanged. This example is only about the deploy.

**Why:**

- **One maintained script, one settings file per site.** [`ploi-script.sh`](../_shared/ploi-script.sh) pastes
  this [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) into
  [`ploi-deploy.sh`](../../src/shell/deploy/ploi-deploy.sh). A fix in the script reaches every site the next
  time you assemble, and the per-site difference stays 20 lines you can review.
- **The first run adopts, it doesn't overwrite.** The existing `.env` is copied to `legacy.example.com-shared/.env`
  (600) with every value kept, then linked back. That's the same file Ploi's environment editor opens.
  `REQUIRED_VARS` stops the deploy *before* anything changes if a key is empty. That catches the ones someone
  "fixed" on the server and never wrote down.
- **Same script for in-place and zero-downtime.** The script detects the `{RELEASE}` placeholder. Switch the
  site to zero-downtime in Ploi later, and the shared `.env` is already where releases expect it.
- **Fail on health, not on hope.** `HEALTHCHECK_CMD` runs last. A deploy that breaks `/health.php` is marked
  failed in Ploi (and notifies you), instead of looking green.
- **Back up the old script first.** `ploi deploy-script` prints the current one. Keep it next to the settings
  file until the new one has deployed twice.

```bash
examples/run.sh ploi-managed-site      # validate (offline): profile checks, the assembled script parses
examples/_shared/ploi-script.sh examples/ploi-managed-site/ploi-deploy.settings.sh > /tmp/legacy-deploy.sh
bin/siwo ploi deploy-script <server-id> <site-id> > ~/legacy-deploy.old.sh            # read-only backup
bin/siwo ploi deploy-script-set <server-id> <site-id> --file /tmp/legacy-deploy.sh --dry-run
bin/siwo ploi deploy-script-set <server-id> <site-id> --file /tmp/legacy-deploy.sh    # asks first
bin/siwo ploi deploy <server-id> <site-id>
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh ploi-managed-site`: settings through `configure --dry-run`, plans |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | the only per-site part: required keys, PHP floor, health check |

Checklist:

- [ ] the site's web directory in Ploi is unchanged (`/` or `/public`): the script never touches Nginx
- [ ] `health.php` (or your route) checks what matters (DB reachable), and answers 200 only then
- [ ] after the first deploy: `ls -l .env` shows a symlink to `legacy.example.com-shared/.env`, mode 600
- [ ] nothing in the repo writes to `.env` at runtime (it is shared by every release now)

Lesson: the old script often has one line nobody remembers why it's there (a `chmod`, a cache folder). Read
the backup line by line, and move anything real into `BUILD_CMDS` or `POST_DEPLOY_CMDS` before the switch.
