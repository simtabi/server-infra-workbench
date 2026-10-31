# Checklist: monthly restore drill

The weekly `restore-test` proves a dump loads. This drill proves you can get the app back, from off-site copies,
on a server that isn't the original. Time it: the result is your real RTO.

1. [ ] Note the start time.
2. [ ] Scratch droplet (same size or smaller), `server init --role db`, copy manager + config, set a
       different `EXPECTED_PRIVATE_IP`, `install`.
3. [ ] Put the off-site key and credentials files in place (0600).
4. [ ] `offsite list`, `offsite fetch <newest>`, `restore <dir> all` (type `RESTORE`).
5. [ ] `verify`; compare row counts of two or three important tables with prd.
6. [ ] If PITR is on: `pitr restore --target '<an hour ago>'` on the scratch server and check a row written
       after the last dump is there.
7. [ ] Point a scratch copy of the app at it and log in.
8. [ ] Note the end time, the RTO and anything that slowed you down; fix the docs if a step was wrong.
9. [ ] Destroy the scratch droplet and delete its copies of the key.
