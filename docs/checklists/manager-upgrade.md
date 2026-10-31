# Checklist: DB manager upgrade

The full procedure is [Roll out a manager upgrade](../recipes/roll-out-a-manager-upgrade.md).

1. [ ] Read the [CHANGELOG](../../CHANGELOG.md) entries between the server's version (`--version`) and the new one.
2. [ ] Maintenance window agreed; the app can tolerate a few seconds of reconnects.
3. [ ] Copy the new script next to the old one, keep the old as `docker-db-server-manager.sh.<old-version>`.
4. [ ] Config: compare with `config/db-server.env.example`; new keys have safe defaults.
5. [ ] `upgrade --dry-run` and read every line of the plan and the diff.
6. [ ] DO snapshot (`--snapshot`, or take one and pass `--snapshot-taken`).
7. [ ] `upgrade` (verified backup, savepoint, apply, verify, doctor; auto-rollback on failure).
8. [ ] `doctor` clean; app `/up` 200; a login and a write in the app.
9. [ ] `cron-install` again (new jobs); `restore-test`.
10. [ ] Note the version and date in the client's notes.
