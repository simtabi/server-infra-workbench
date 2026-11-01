# Recipe: migrate databases to a managed PostgreSQL

**Why a copy and not a cutover:** `migrate-managed` only reads the source. You can run it as often as you like
(a rehearsal now, the final sync in a maintenance window), and you switch the app yourself, so rolling back
is just pointing `DB_HOST` back.

**Security:** the target credentials sit in a root-only file (600). They reach `pg_dump`/`pg_restore` through
a temporary env file, never argv, and are never printed or logged. Plain connections (`sslmode=disable`) are
refused.

## Steps

1. Create the managed cluster in the **same region** as the web server, and add the web server and the DB
   server as trusted sources.
2. On the DB server, write the target file (`sudo install -m 600 /dev/null /root/managed.env`, then edit it):

   ```ini
   TARGET_HOST=private-db-xxxx.db.ondigitalocean.com
   TARGET_PORT=25060
   TARGET_USER=doadmin
   TARGET_PASSWORD=...
   TARGET_SSLMODE=verify-full
   TARGET_SSLROOTCERT=/root/managed-ca.crt
   #TARGET_DB_PREFIX=
   ```

   The file holds only strict `KEY=VALUE` lines. It is parsed, never sourced, and must be mode 600.
3. Check: `sudo /root/docker-db-server-manager.sh migrate-managed --target-env /root/managed.env --check`. This tests the connection, checks
   the target version is at least the source version and that every extension exists there, and copies
   nothing.
4. Rehearse: run it without `--check` (type `MIGRATE`). Every table's row count is compared.
5. Cutover: put the app in maintenance mode, re-run step 4 (final sync), set `DB_HOST`, `DB_PORT`,
   `DB_SSLMODE` and the managed user/password in the web `.env`, deploy, then leave maintenance mode.
6. Keep the old server read-only for a week before you retire it.

## Checklist

- [ ] Trusted sources set, same region
- [ ] `--check` passes (versions, extensions)
- [ ] Rehearsal: `MIGRATE OK`
- [ ] Final sync in maintenance mode, app switched, smoke test passed
- [ ] Old server kept read-only for a week

## Lessons learned

- `--no-owner --no-privileges`: managed services don't give you a superuser, so restoring the original
  owners would fail half-way. The target user owns everything instead.
- Row counts catch silent partial restores (an extension missing, a permission error). Exit codes alone
  don't.
