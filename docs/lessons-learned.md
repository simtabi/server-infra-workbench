# Lessons learned

Things that went wrong (or nearly did) while building and running these servers, and what changed because of
them. Each one is a rule the tools now follow. No client names or addresses: examples use `myapp` and
documentation IP ranges.

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
| `eth0` is public, `eth1` is the VPC | the wrong interface was used for the bind address | `PRIVATE_IFACE=eth1` and `EXPECTED_PRIVATE_IP` (wrong-server guard) |

## Databases

| Lesson | What happened | Rule now |
|---|---|---|
| The app login was a superuser | the container's bootstrap user doubled as the Laravel login, so any SQL injection could drop everything | role split in 1.4.0 ([ADR 0010](adr/0010-least-privilege-database-roles.md)); `doctor` fails on superuser app logins |
| `root@'%'` on MySQL | the official image creates it by default | new installs set `MYSQL_ROOT_HOST=localhost`; `upgrade` removes it |
| `_` is a wildcard in MySQL grants | a grant on `myapp_prd%` also matched `myappXprd...` | names are escaped (`myapp\_prd\_t\_%`); `doctor` warns on unescaped grants |
| A new Postgres major can't start on old data | bumping the image tag 18 -> 19 would break the server | bump only the minor tag in place; a major version follows the dump/restore path in [status](status.md#postgres-major-upgrade) |
| Four engines on 1.9 GB | the server swapped and the OOM killer stopped MySQL | RAM estimates in [sizing](reference/sizing.md); `doctor` and `engine enable` warn and print the resize command |
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
| Keep the console path ready | | provider consoles and the recovery ISO steps are in the recipe; test it once on a scratch droplet |

## Shell scripting

| Lesson | What happened | Rule now |
|---|---|---|
| BSD and GNU `sed` differ | `sed -n '...{...p}'` works on GNU and fails on macOS | write `p;}`; tests run on macOS and Linux |
| `cmd \| grep -q` fails under `pipefail` | `grep -q` exits early, `cmd` gets SIGPIPE, the pipeline "fails" | tests write output to a file, then grep the file |
| `set -e` hides the failing line | a smoke test exited silently | expected failures get `\|\| true`; each test prints its name first |
| `/dev/stderr` truncates a redirected log in containers | messages disappeared in Docker | duplicate stderr to a dedicated fd once (`exec 4>&2`) |
| Reading a TTY in a loop | a menu re-read the first line forever at EOF | open the TTY once on its own fd and stop on EOF |

## Process

| Lesson | Rule now |
|---|---|
| Plans before changes | every tool prints a plan and has `--dry-run`; destructive steps need a typed word; protected envs need `--force-prod` |
| Writes are audited | `/var/log/vps-server-workbench/audit.log` and syslog, with fingerprints and names, never secrets |
| Client data doesn't belong in a shared repo | client notes live in gitignored `local/<client>/`; `make client-check` and a secret scan run before every push |
| Pin versions, upgrade on purpose | images and packages are pinned; `upgrade --dry-run` shows the diff first |
