# Lessons learned

Things that went wrong (or nearly did) while building and running these servers, and what changed because of
them. Each one is a rule the tools now follow. No client names or addresses: examples use `myapp` and
documentation IP ranges.

## Always look out for

1. **Where am I?** Read the prompt before pasting: Mac commands don't work on the server and the reverse.
2. **Which IP?** Private VPC IP for DB traffic, never the public one; same region, same VPC.
3. **Which port?** The app uses PgBouncer on 6432; 5432 is for session work and admin tools.
4. **Docker ignores ufw.** Bind to the private IP and use a DO cloud firewall.
5. **Test from the real client**, not from the server to its own public IP (hairpin).
6. **No superuser app login, no `root@'%'`.** `doctor` checks both.
7. **RAM.** Count each engine before enabling it; turn off what the app doesn't use.
8. **Backups off the droplet**, encrypted, with the key stored elsewhere, and restored at least monthly.
9. **Empty DB + 503** means migrations never ran.
10. **One command per interactive prompt** (`doctl auth init`, `passwd`): no multi-line pastes.
11. **Which SSH client holds the key?** Termius keys aren't on your Mac.
12. **Keep a console session or the DO console ready** before touching SSH or the firewall.

## Contents

- [Networking](#networking)
- [Databases](#databases)
- [Backups](#backups)
- [SSH and access](#ssh-and-access)
- [Shell scripting](#shell-scripting)
- [Process](#process)

## Networking

| Lesson | What happened | Rule now |
|---|---|---|
| The first VPC in a region becomes its default | a rehearsal created an isolated `/24` VPC in a region with no VPC yet; DigitalOcean made it the region default, then refused to delete it | before a throwaway VPC, check `doctl vpcs list` for a default in that region; if none, create `default-<region>` first (let DO pick the range). To undo: create one, `doctl vpcs update <id> --name default-<region> --default=true`, then delete the old one |
| The DB is unreachable from the web server | the `.env` used the droplet's **public** IP, or port 5432 when the app should use PgBouncer on 6432 (or the reverse) | `env-creds` and `env` print the private IP and the right port; `web diagnose` lists the usual causes: public vs private IP, 6432 vs 5432, the DO cloud firewall or ufw, containers down |
| Docker-published ports bypass ufw | a `0.0.0.0:5432` mapping was reachable from the internet with ufw "deny" | every port binds to `PRIVATE_IP`; `doctor` "Exposure" fails on any public listener |
| Commands meant for the Mac were run on the server | `scp ~/Downloads/...` typed inside an SSH session failed: `~/Downloads` doesn't exist there and the server has no key to itself | look at the prompt before pasting; docs mark each block "on your workstation" or "on the server"; `remote-run.sh` does the upload from the workstation |
| The ufw hairpin | a test from the DB server to its own **public** IP passed or failed differently from the real path, because traffic to your own public address loops back and skips the cloud firewall and parts of ufw | test from the other server: `bin/workbench web check-db-reach --remote <web> <db-private-ip> 6432 5432` |
| The wrong IP | a public IP, the old server's IP or the DB's IP in another VPC was in `DB_HOST` | private VPC IP only; `env-creds` prints it; `check-db-reach` warns on a public address or one outside this droplet's VPC |
| PgBouncer 6432 vs Postgres 5432 | the app used 5432 directly (connection storms) or tools that need session features went through 6432 | the app uses 6432 (`DB_PORT=6432`); migrations or `pg_dump` that need session state use 5432 from the VPC; both allowed only from the VPC |
| VPCs are per region | a web server in another region couldn't reach the DB's private IP at all | build peers in one region; otherwise VPC peering, WireGuard or public TLS with an allowlist ([cross-region](cross-region.md)); `doctor` and `check-db-reach` check the region |
| `eth0` is public, `eth1` is the VPC | the wrong interface was used for the bind address | `PRIVATE_IFACE=eth1` and `EXPECTED_PRIVATE_IP` (wrong-server guard) |
| The default tunnel subnet can be a VPC | WireGuard's 10.200.0.0/24 overlapped a VPC in the same range, which would have hijacked VPC routes | `net wireguard setup` refuses an overlapping /24 (exit 2) and suggests 10.250.0.x |

## Databases

| Lesson | What happened | Rule now |
|---|---|---|
| `\x27` is not a quote in a shell string | an ad-hoc audit over ssh wrote `psql -c "... \x27template1\x27"`; bash kept `\x27` literally and Postgres logged five syntax errors (nothing ran) | send ad-hoc SQL from a quoted heredoc with psql variables (`:'v'`, `:"v"`); `log-errors` / `pg-log-errors` classify it, `doctor` warns on log errors, a test bans `\x27` in toolkit SQL ([plan](plan/postgres-log-quoting-errors.md)) |
| A new Postgres major would not start next to the old data | the 18+ image entrypoint refuses to init 19 while `18/docker` exists in the same volume | `pg-major-upgrade` renames the old directory to `.pg18-old` (kept for rollback, removed by `--cleanup`); the container test runs the real 18 to 19 path |
| A dry run died without a message | `df` piped under `pipefail`, and a decimal size from `sum(pg_database_size())` in shell arithmetic, aborted the `set -e` script | `$(...) \|\| fallback` for optional probes; SQL returns `ceil(...)::bigint` for anything the shell counts |
| MySQL "ready" before it accepts TCP | the restore test's socket ping passed while the TCP listener was still starting | wait with `-h127.0.0.1 --protocol=TCP`, the path the clients use |
| Managed targets have no superuser | restoring owners and grants failed half-way into a managed database | `migrate-managed` restores with `--no-owner --no-privileges` and compares every table's row count |
| The app login was a superuser | the container's bootstrap user doubled as the Laravel login, so any SQL injection could drop everything | role split in 1.4.0 ([ADR 0010](adr/0010-least-privilege-database-roles.md)); `doctor` fails on superuser app logins |
| `root@'%'` on MySQL | the official image creates it by default | new installs set `MYSQL_ROOT_HOST=localhost`; `upgrade` removes it |
| `_` is a wildcard in MySQL grants | a grant on `myapp_prd%` also matched `myappXprd...` | names are escaped (`myapp\_prd\_t\_%`); `doctor` warns on unescaped grants |
| A new Postgres major can't start on old data | bumping the image tag 18 -> 19 would break the server | bump only the minor tag in place; a major version follows the dump/restore path in [status](status.md#postgres-major-upgrade) |
| Four engines on 1.9 GB | the server swapped and the OOM killer stopped MySQL | RAM estimates in [sizing](reference/sizing.md); `doctor` and `engine enable` warn and print the resize command |
| An empty staging database behind a 503 | the stg site returned 503 and the DB had no tables: the first deploy never ran migrations (and the site stayed in maintenance mode) | `web diagnose` reports pending migrations and maintenance mode; the deploy script runs `migrate --force`; check `php artisan migrate:status` first |
| Extensions missing on new databases | `citext` was added to the config after the first install | extensions are created in `template1` too, and `upgrade` converges them |
| A restored snapshot keeps the old private IP | a clone of the DB droplet on a new VPC IP had every container exit: they bind `PRIVATE_IP` from `/opt/db/.env` | `rebind-ip` rewrites it and starts the stack; `upgrade` preflight names it |
| A legacy stack sat on `db_default` | the first `upgrade` of a pre-1.4 stack failed with "network has active endpoints" and rolled back | the apply moves the stack's containers to `DOCKER_NETWORK` (volumes kept) before Postgres starts |
| An old image tag outlived its upgrade | a stack from before `stack.env` named its custom tag only on the container, so `upgrade` never retired it | the running container's tag joins `PG_IMAGE_LEGACY`; a no-op `upgrade` retires old tags too |

## Backups

| Lesson | What happened | Rule now |
|---|---|---|
| A backup that was never restored is unproven | dumps can be empty or truncated and still "succeed" | manifest + checksums on every backup; weekly `restore-test` into throwaway containers with no network |
| Half-written backups counted as good | a full disk left a partial dump that pruning kept and an old good one was deleted | write to `.partial-<ts>`, rename only on success, refuse below `MIN_FREE_MB` |
| Backups on the same droplet die with it | | encrypted off-site copies, key stored off the server ([backups](backups-and-recovery.md)) |
| Nightly dumps lose up to a day | | pgBackRest PITR for Postgres, binlog shipping for MySQL/MariaDB |
| Cleanup traps don't always fire | a `RETURN` trap didn't run in a cron restore test, leaving containers using RAM | explicit cleanup on every exit path, and leftovers removed at the start of the next run |
| A docker error parsed as a version | `pitr setup` on an image without pgBackRest read "OCI runtime exec failed" and took "runtime" for the version | the version must be `pgBackRest N.N`; the error says to set `PITR` and run `upgrade` |
| Turning PITR on rolled itself back | the upgrade that adds pgBackRest ran doctor before `pitr setup` could create the stanza | in the upgrade's doctor a missing stanza is a warning |
| Docker DNS ignores `/etc/hosts` | a private S3 name in the host's `/etc/hosts` reached `offsite` but not pgBackRest in the container | `PITR_S3_HOST_IP` adds `extra_hosts` to the postgres service |
| `AWS_CA_BUNDLE` breaks rclone | exporting it for a private CA made rclone's S3 SDK fail with "unsupported transport" | rclone gets `RCLONE_CA_CERT`, aws gets `AWS_CA_BUNDLE`, never both |
| A MySQL dump would not load back into its own server | `restore` (and the new replay) failed with ERROR 3546: GTIDs are on in MySQL 9.7, so `mysqldump` wrote `SET @@GLOBAL.GTID_PURGED` that overlaps the server's own executed set | dumps use `--set-gtid-purged=OFF`; replays use `mysqlbinlog --skip-gtids` (otherwise the server silently skips every replayed transaction as already executed); `mysql-pitr-it` covers both engines |
| The MySQL image has no `mysqlbinlog` | binlog shipping existed but nothing in the default image could decode the binlogs | `binlog-replay` builds a decoder from the same image plus Oracle's client RPM of the same version, signature checked; `MYSQLBINLOG_IMAGE` for offline servers |
| Replaying account changes undoes them | a binlog replay re-ran `CREATE USER`/`ALTER USER` from before a password rotation, reverting it or failing on existing users | the replay skips account statements and reports how many; accounts stay as they are now |
| Binlog PITR needs a starting point | dumps did not record where in the binlog they were taken, so there was nothing to replay from | `backup` writes the binlog file and position (`--source-data`/`--master-data`) and the dump's UTC finish time |

## SSH and access

| Lesson | What happened | Rule now |
|---|---|---|
| A hardening change can lock you out | an sshd drop-in disabled the only working login | `server harden` runs `sshd -t` before any reload and rolls the drop-in back if it fails; keep your current session open and test a new login before closing it |
| Key problems are usually permissions | `~/.ssh` group-writable, CRLF line endings from a pasted key, the wrong `AuthorizedKeysFile` | `fixkeys.sh diagnose` checks each one; [lockout recipe](recipes/recover-ssh-lockout.md) for the console |
| Multi-line pastes into interactive prompts | pasting a block that started with `doctl auth init` fed the following lines into the token prompt, so the "token" was the rest of the commands | run interactive commands on their own line, wait for the prompt, then paste only the answer; tools read tokens from the credentials file instead |
| Keys in Termius are not keys on your Mac | a key generated or imported in Termius lives in Termius's vault; `ssh` in Terminal, `scp`, `remote-run.sh` and the workbench can't use it, and adding "the Mac key" to a server didn't help Termius | decide which client holds the key; export the **public** key from Termius when a server needs it; `keys fingerprint` compares what each side has |
| Keep the console path ready | | provider consoles and the recovery ISO steps are in the recipe; test it once on a scratch droplet |

## Shell scripting

| Lesson | What happened | Rule now |
|---|---|---|
| BSD and GNU `sed` differ | `sed -n '...{...p}'` works on GNU and fails on macOS | write `p;}`; tests run on macOS and Linux |
| `cmd \| grep -q` fails under `pipefail` | `grep -q` exits early, `cmd` gets SIGPIPE, the pipeline "fails" | tests write output to a file, then grep the file; scripts send grep to `/dev/null` instead of `-q` (P2: Beszel self-registration was silently skipped) |
| `set -e` hides the failing line | a smoke test exited silently | expected failures get `\|\| true`; each test prints its name first |
| `/dev/stderr` truncates a redirected log in containers | messages disappeared in Docker | duplicate stderr to a dedicated fd once (`exec 4>&2`) |
| `$(… \| grep -o … \| wc -l)` under `set -e` + `pipefail` | zero matches made grep exit 1 and `monitor doctor` stopped mid-report | count with `awk`, or end the substitution with `\|\| true` |
| Prometheus `file_sd` on Docker Desktop | a renamed targets file on the host was not seen for 5 minutes | `refresh_interval: 30s` on every `file_sd_configs` |
| Reading a TTY in a loop | a menu re-read the first line forever at EOF | open the TTY once on its own fd and stop on EOF |

## Process

| Lesson | Rule now |
|---|---|
| Plans before changes | every tool prints a plan and has `--dry-run`; destructive steps need a typed word; protected envs need `--force-prod` |
| Writes are audited | `/var/log/vps-server-workbench/audit.log` and syslog, with fingerprints and names, never secrets |
| Client data doesn't belong in a shared repo | client notes live in gitignored `local/<client>/`; `make client-check` and a secret scan run before every push |
| Pin versions, upgrade on purpose | images and packages are pinned; `upgrade --dry-run` shows the diff first |

## Testing and CI

| Lesson | What happened | Rule now |
|---|---|---|
| Monitoring can take the database down | Prometheus + Grafana need about 700 MB; on a 2 GB DB droplet that is the OOM killer's next target | `monitor plan` gates RAM (exit 3) and the profiles default to Beszel + Kuma ([ADR 0012](adr/0012-monitoring-stack.md)) |
| Integration suites that share Docker interfere | two suites running at once made a healthy Postgres look unhealthy | `make it` runs suites one after another; each suite uses its own ports, subnet and project name (see the leftover-network row) |
| Test passwords are still passwords to a scanner | GitGuardian raised 4 incidents for test fixtures | every secret is generated at runtime; `make secrets-check` (scanner + gitleaks) runs in `make ci` and pre-push |
| `--help` that nobody reads breaks quietly | 12 tools printed only their title: `sed -n '2,/=====/p'` ends at the title box's closing rule | `usage()` counts the rules with awk; `make docs-commands` runs every tool's `--help` and checks each documented subcommand and flag against it |
| CI and laptops ran different shellcheck versions | ubuntu-latest's 0.9 flagged SC2015/SC2119 that 0.11 does not, and a SC2317 disable was dead | one pinned version (`SHELLCHECK_VERSION`, docker image when the local binary differs); `make ci-local` |
| Dependabot cannot read `${X_IMAGE:-repo:tag}` | the docker-compose entry had nothing it could update; the composer entry pointed at a stale `/php` | composer path fixed, compose entry removed with the reason; image pins move with `upgrade --dry-run` |
| pgBackRest's S3 driver speaks HTTPS only | a plain `http://` Garage endpoint cannot hold a PITR repo; the first design would have failed only on the server | `validate` refuses a non-https endpoint; private endpoints get `PITR_S3_CA_FILE` and path style; `pitr-s3-it` restores through a TLS front with a per-run CA |
| A check on a file that is never written passes vacuously | the "secret never logged" grep named `run.log`, which only `upgrade` writes | integration checks read the captured outputs that exist (`cat ... 2>/dev/null \| grep`) |
| A row in the wrong table loses a column silently | six 3-column lessons sat in the 2-column Process table, so GitHub dropped their rule | `tests/docs/check-tables.py` in `make docs-commands` fails on a cell count that differs from the header |
| Cluster state arrives late | the third Garage node read the layout before the other nodes' staged roles had reached it, and node 1 still listed a restarted node as down after it served again | `addon.sh` waits for every peer's role in `layout show` before deciding; tests wait for the observer's view, not another node's |
| "Not container-tested" lists rot | Garage host mode, RustFS and multi-node Garage were listed as untested in three docs for two phases | one container test per listed gap (`garage-cluster-it`, RustFS in `addons-it`); the list in `docs/status.md` is updated in the same commit |
| A test measured the laptop, not the server | upgrade-it failed only some days: `doctor` checks disk use on `DB_DIR`, which in a suite is the Mac's `/tmp` (90% full), so `upgrade` saw a PROBLEM and rolled back; the failure output was `tail -60`, which had scrolled past the PROBLEM line | host-dependent limits are keys (`DOCTOR_DISK_*_PCT`, `ADDON_DISK_*_PCT`) the suites set; failures print the PROBLEM lines first (`it_why`) |
| An unreachable archive repo slows the first boot | `pitr-s3-it` failed intermittently: the endpoint did not resolve during `install`, so `archive_command` could wait out pgBackRest's timeout and the init server took over 60 s to stop (the new `up_wait` diagnostics showed `pg_ctl: server does not shut down`) | the repo must answer before `install` with PITR on (documented); the test attaches its S3 front when the network appears |
| A leftover network breaks the next suite | `compose down` cannot remove a network a foreign container (a TLS front, a restore test) is still attached to; it kept its fixed subnet, and three suites used 172.30.97.0/24, so the monitor and upgrade suites failed intermittently after another suite | `it_purge` removes a project's containers, networks and volumes by label; one subnet per suite; `run-suites.sh` fails a suite that leaks `vsw*` objects |
| A default that needs a specific image | `monitor-it` went "postgres unhealthy" some runs: it used `postgres:18` with the default `PG_EXTENSIONS` (which has postgis), so first-boot init failed and only a lucky restart made `install` pass; the `up_wait` log lines finally showed `extension "postgis" is not available` | `validate_config` refuses an extension the base image cannot have; every suite sets `PG_EXTENSIONS` for its base; failure output prints the container log, never just "unhealthy" |
| `producer | grep -q` under pipefail, again | `server-it` failed 3 of 7 runs at "sshd -T"; once the check stopped hiding stderr, sshd printed the right lines: grep had matched, exited, and SIGPIPE on sshd made the pipeline false (the bug 210ed15 fixed in the tools) | capture multi-chunk output in a variable, then `grep <<<"$out"`; never silence a failing check's stderr |
| Some things only a real cloud proves | Spaces host-style URLs and its public CA, `--host` over real ssh, swap and Docker on a real kernel, Garage across real hosts were "not container-tested" for three phases | opt-in live tests on throwaway DigitalOcean resources ([live tests](live-tests.md)): dry run by default, cost guard, trap teardown, verified cleanup, never in CI |
| A region's first VPC can never be deleted | the first VPC in a region becomes its default; a test that made its own VPC there would leave one behind for good | the live tests refuse a region without a VPC unless `--create-default-vpc` makes `default-<region>` first |
| doctl reports API errors on stdout | with `-o json`, a 422 ("tag does not exist") went into the parsed output and `set -e` ended the test without a word; the firewall also needs its tags to exist before any droplet has them | `live_create` shows the API's reason; the tags are created first; the API omits `"default": false`, so absent means false |
| A second signal cut the teardown short | interrupting a live run killed its teardown too and left three droplets running until `sweep.sh` | teardown ignores INT/TERM/HUP; the watchdog's `sleep` dies with it; `make live-sweep` finds anything named `vswlt-*` |
| Deleting the last Spaces bucket is how Spaces is turned off | there is no cancel call in the API or doctl; the $5/month subscription starts with the first bucket and ends with the last | the Spaces test deletes its bucket, waits for the bucket list to drop it, and reports the count; `sweep.sh --buckets` checks every region |
| A MySQL-only install was refused | `validate_config` checked Postgres extensions against the base image even with `ENABLE_POSTGRES=0` | the check runs only when Postgres is on |
