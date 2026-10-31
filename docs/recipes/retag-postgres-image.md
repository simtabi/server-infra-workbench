# Recipe: retag a custom Postgres image to the default name

**Why:** early servers built the Postgres image under a custom tag, sometimes one that names the project
(`PG_IMAGE=<name>/postgres:18-postgis-pgvector`). The tag ends up in `docker images`, the compose file and every
support screenshot. The default `vsw/postgres:18-postgis-pgvector` is neutral, and it is what the docs and
tests assume. The image content does not change: same Dockerfile, same base, same extensions. The data lives
in the volume, not in the image.

**What `upgrade` already does:** when `PG_IMAGE` in the config differs from the tag the stack was built with
(`/opt/db/stack.env`), it builds under the new tag, recreates the container (a few seconds of reconnects
through PgBouncer) and, after a successful verify, removes the old tag. On failure the automatic rollback
re-tags the saved image under the old name.

## Steps

1. In your server config (the gitignored `local/<project>/db-server.conf`), delete the `PG_IMAGE=...` line,
   or set it to `vsw/postgres:18-postgis-pgvector`.
2. Dry run from the workbench folder. It must show `PG_IMAGE` changing and nothing else you did not expect:

   ```bash
   src/shell/db/remote-run.sh --host db-alias --expect-ip 10.0.0.5 --config db-server.conf -- upgrade --dry-run
   ```

3. Apply it in a quiet window: the same command without `--dry-run`. Look for `retired old image tag ...` and
   `UPGRADE OK`.
4. Check on the server: `docker images | grep postgres` shows only `vsw/postgres` (plus `vsw/postgres:pre-upgrade`
   until the next upgrade), and `sudo /root/docker-db-server-manager.sh doctor` reports 0 problems.

## Checklist

- [ ] Config has no custom `PG_IMAGE`
- [ ] `upgrade --dry-run` diff reviewed
- [ ] `upgrade` printed `retired old image tag` and `UPGRADE OK`
- [ ] `doctor` clean, the app connects

## Lessons learned

- Names in image tags leak into places you can't easily scrub (registries, logs, screenshots). Keep project
  names in the gitignored `local/` folder only.
- Never `docker image rm` the old tag by hand before the upgrade has passed: it is the rollback image.
