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
| The DB is unreachable from the web server | the `.env` used the droplet's **public** IP, or port 5432 when the app should use PgBouncer on 6432 (or the reverse) | `env-creds` and `env` print the private IP and the right port; `web diagnose` lists the usual causes: public vs private IP, 6432 vs 5432, the DO cloud firewall or ufw, containers down |
| Docker-published ports bypass ufw | a `0.0.0.0:5432` mapping was reachable from the internet with ufw "deny" | every port binds to `PRIVATE_IP`; `doctor` "Exposure" fails on any public listener |
| Commands meant for the Mac were run on the server | `scp ~/Downloads/...` typed inside an SSH session failed: `~/Downloads` doesn't exist there and the server has no key to itself | look at the prompt before pasting; docs mark each block "on your workstation" or "on the server"; `remote-run.sh` does the upload from the workstation |
| The ufw hairpin | a test from the DB server to its own **public** IP passed or failed differently from the real path, because traffic to your own public address loops back and skips the cloud firewall and parts of ufw | test from the other server: `bin/workbench web check-db-reach --remote <web> <db-private-ip> 6432 5432` |
| The wrong IP | a public IP, the old server's IP or the DB's IP in another VPC was in `DB_HOST` | private VPC IP only; `env-creds` prints it; `check-db-reach` warns on a public address or one outside this droplet's VPC |
| PgBouncer 6432 vs Postgres 5432 | the app used 5432 directly (connection storms) or tools that need session features went through 6432 | the app uses 6432 (`DB_PORT=6432`); migrations or `pg_dump` that need session state use 5432 from the VPC; both allowed only from the VPC |
| VPCs are per region | a web server in another region couldn't reach the DB's private IP at all | build peers in one region; otherwise VPC peering, WireGuard or public TLS with an allowlist ([cross-region](cross-region.md)); `doctor` and `check-db-reach` check the region |
| `eth0` is public, `eth1` is the VPC | the wrong interface was used for the bind address | `PRIVATE_IFACE=eth1` and `EXPECTED_PRIVATE_IP` (wrong-server guard) |

## Databases

| Lesson | What happened | Rule now |
|---|---|---|
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

## Backups

| Lesson | What happened | Rule now |
|---|---|---|
| A backup that was never restored is unproven | dumps can be empty or truncated and still "succeed" | manifest + checksums on every backup; weekly `restore-test` into throwaway containers with no network |
| Half-written backups counted as good | a full disk left a partial dump that pruning kept and an old good one was deleted | write to `.partial-<ts>`, rename only on success, refuse below `MIN_FREE_MB` |
| Backups on the same droplet die with it | | encrypted off-site copies, key stored off the server ([backups](backups-and-recovery.md)) |
| Nightly dumps lose up to a day | | pgBackRest PITR for Postgres, binlog shipping for MySQL/MariaDB |
| Cleanup traps don't always fire | a `RETURN` trap didn't run in a cron restore test, leaving containers using RAM | explicit cleanup on every exit path, and leftovers removed at the start of the next run |

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
| Monitoring can take the database down | Prometheus + Grafana need about 700 MB; on a 2 GB DB droplet that is the OOM killer's next target | `monitor plan` gates RAM (exit 3) and the profiles default to Beszel + Kuma ([ADR 0012](adr/0012-monitoring-stack.md)) |
| Integration suites that share Docker interfere | two suites running at once made a healthy Postgres look unhealthy | `make it` runs suites one after another; each suite uses its own ports, subnet and project name |
| Test passwords are still passwords to a scanner | GitGuardian raised 4 incidents for test fixtures | every secret is generated at runtime; `make secrets-check` (scanner + gitleaks) runs in `make ci` and pre-push |
| `--help` that nobody reads breaks quietly | 12 tools printed only their title: `sed -n '2,/=====/p'` ends at the title box's closing rule | `usage()` counts the rules with awk; `make docs-commands` runs every tool's `--help` and checks each documented subcommand and flag against it |
| CI and laptops ran different shellcheck versions | ubuntu-latest's 0.9 flagged SC2015/SC2119 that 0.11 does not, and a SC2317 disable was dead | one pinned version (`SHELLCHECK_VERSION`, docker image when the local binary differs); `make ci-local` |
| Dependabot cannot read `${X_IMAGE:-repo:tag}` | the docker-compose entry had nothing it could update; the composer entry pointed at a stale `/php` | composer path fixed, compose entry removed with the reason; image pins move with `upgrade --dry-run` |
| Pin versions, upgrade on purpose | images and packages are pinned; `upgrade --dry-run` shows the diff first |
