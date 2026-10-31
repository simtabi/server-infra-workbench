# stacks/

Docker Compose stacks that are deployed to servers.

| Folder | What | Docs |
|---|---|---|
| [`caddy/`](caddy) | the app in containers behind Caddy with automatic HTTPS (alternative to Ploi's nginx) | [caddy-stack.md](../docs/tools/caddy-stack.md) |

There is no `db/` stack here on purpose: the database stack (Postgres, PgBouncer, MySQL, Redis, MongoDB,
backups) is **generated on the server** by
[`src/shell/db/docker-db-server-manager.sh`](../src/shell/db/docker-db-server-manager.sh) from
`/etc/docker-db-server-manager.conf`, so it always matches that server's settings.

`make compose-check` validates every stack.
