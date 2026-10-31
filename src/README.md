# src/

All source code, grouped by language, then by area.

| Folder | What | Run it with | Docs |
|---|---|---|---|
| [`shell/db/`](shell/db) | DB server manager (runs on the server) and `remote-run.sh` (runs it from your workstation) | `bin/workbench db <tool>` | [db-server-manager.md](../docs/tools/db-server-manager.md) |
| [`shell/web/`](shell/web) | web-server helpers: point `.env` at the DB, check DB reachability | `bin/workbench web <tool>` | [configure-a-ploi-web-server.md](../docs/recipes/configure-a-ploi-web-server.md) |
| [`shell/deploy/`](shell/deploy) | `ploi-deploy.sh`, pasted into Ploi's deploy script | `bin/workbench deploy ploi-deploy` | [deploy-script.md](../docs/tools/deploy-script.md) |
| [`shell/tunnels/`](shell/tunnels) | workstation SSH tunnels to the DB | `bin/workbench tunnels db-tunnel` | [connect-to-databases.md](../docs/recipes/connect-to-databases.md) |
| [`php/`](php/README.md) | Composer package: DigitalOcean, Cloudflare, Ploi, GCP clients and the CLI core | `bin/workbench do\|cf\|ploi\|gcp` | [platform-api.md](../docs/tools/platform-api.md) |
| [`python/`](python/README.md) | Python package: `ping`, `plans` | `bin/workbench py\|plans` | [python.md](../docs/tools/python.md) |
