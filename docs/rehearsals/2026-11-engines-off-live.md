# Engines off on a live DB server, 2026-11

A generalised account of switching MySQL and MariaDB off on a production DB server that serves a
Postgres-only Laravel app, done by hand because the scripted run first failed, followed by how the tools were
fixed and the same state reproduced in the Docker integration test (`tests/shell/db-users-it.sh`).
Hostnames, addresses and client names are left out on purpose; every `<...>` is a placeholder.

## Starting point

| Item | State |
|---|---|
| Engines running | Postgres, PgBouncer, MySQL, MariaDB (Adminer off) |
| App | Postgres only, through PgBouncer |
| Server config | **`/opt/db/.env` only.** There was no `/etc/docker-db-server-manager.conf`; the manager reads that file if present, then `/opt/db/.env`, which wins for every key it holds |
| Login | the panel's `ploi` user: sudo needs its password; member of the `docker` group |
| Goal | free the RAM of the two unused engines with no Postgres or PgBouncer restart, data kept |

## What failed first, and why

1. `remote-run.sh --host <db-alias> ...` → `zsh: no such file or directory: db-alias`. The placeholder was
   pasted literally; the shell read `<db-alias>` as an input redirection and never started the script.
2. With a real host, the run stopped at sudo: the login user's sudo wants a password and the session (an
   automated one) had no terminal. `--dry-run` had been written after `--`, where it is the manager's plan:
   that still connects and still needs sudo.
3. Had it reached the server, the 1.5 manager would have stopped with "no config" (it wrote engine settings
   only to the `/etc` file, which did not exist).

All three are fixed (remote-run placeholder check, sudo probe and `ssh -t`, `/opt/db/.env` support and
drift detection in `engines apply`); see [remote-run](../tools/remote-run.md) and
[turning engines on and off](../databases/users-and-privileges.md#turning-engines-on-and-off).

## The manual change

### 1. Persist the setting (needs sudo; asks for the password once, in a terminal)

Back up `/opt/db/.env`, then set both keys, replacing an existing line or appending one. Running it twice
leaves the same values (plus one more backup):

```sh
ssh -t <user>@<db-public-ip> 'sudo sh -c '\''f=/opt/db/.env; cp -p "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"; for k in ENABLE_MYSQL ENABLE_MARIADB; do if grep -q "^$k=" "$f"; then sed -i -E "s/^$k=.*/$k=0/" "$f"; else echo "$k=0" >> "$f"; fi; done; grep -E "^ENABLE_(MYSQL|MARIADB)=" "$f"'\'''
```

`-t` gives sudo a terminal for its prompt; the password is typed there, never put on the command line. Add
`-i ~/.ssh/<db-key> -o IdentitiesOnly=yes` if the key is not your default. If the server also has
`/etc/docker-db-server-manager.conf` with these keys, set them there as well (or let `engines apply` do both).

### 2. Stop and remove the containers (docker group is enough, no sudo)

A login user in the `docker` group can do this part without sudo. Disable the restart policy first so the
container cannot come back, then stop and remove it. **Volumes are not touched** (`docker rm` without `-v`):

```sh
ssh <user>@<db-public-ip> 'for s in mysql mariadb; do c=$(docker ps -aq --filter label=com.docker.compose.project=db --filter label=com.docker.compose.service=$s); [ -n "$c" ] || { echo "$s: already gone"; continue; }; docker update --restart=no $c && docker stop -t 30 $c && docker rm $c; done'
```

Step 2 alone is not enough: without step 1 the next `install`, `upgrade` or `engines apply` reads
`ENABLE_*=1` and starts them again. A user in the `docker` group can also read `/opt/db` through a container
mount, which is why docker-group membership is effectively root; treat it that way.

### 3. Verify

```sh
ssh <user>@<db-public-ip> 'docker ps --format "table {{.Names}}\t{{.Status}}"'      # only postgres and pgbouncer
ssh <user>@<db-public-ip> 'for s in postgres pgbouncer; do docker inspect -f "{{.Name}} {{.Id}} {{.State.StartedAt}}" $(docker ps -q --filter label=com.docker.compose.service=$s); done'
ssh <user>@<db-public-ip> 'free -m'                                              # "used" lower, "available" higher
ssh <user>@<db-public-ip> 'docker volume ls --filter name=db_'                    # db_mysql_data and db_mariadb_data still there
```

Run the `docker inspect` line **before** step 2 too and compare: the Postgres and PgBouncer container IDs and
`StartedAt` times must be identical (same containers, no restart). On the real server the two engines had
been using a few hundred MB together.

### 4. Let the tools catch up (optional, recommended)

After a manual change the generated `/opt/db/docker-compose.yml` still lists the two services, and the ufw
rules for their ports may remain. The manager now sees this as drift; its plan shows only what is left:

```sh
src/shell/db/remote-run.sh --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> --no-config -- engines apply --set ENABLE_MYSQL=0 --set ENABLE_MARIADB=0 --dry-run
```

```text
  files   regenerate docker-compose.yml: mysql mariadb off, container already gone, still listed
  ufw     remove the 3306/tcp rule
```

Without `--dry-run` (in a terminal; type `APPLY`) it regenerates the file and prunes the rules; Postgres and
PgBouncer are checked to be the same containers. A second run prints `nothing to change`. `--no-config` keeps
the server on `/opt/db/.env` alone (no `/etc` file uploaded from your workstation's `.env`).

## Re-enabling an engine

```sh
src/shell/db/remote-run.sh --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> --no-config -- engines apply --set ENABLE_MYSQL=1 --dry-run
src/shell/db/remote-run.sh --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> --no-config -- engines apply --set ENABLE_MYSQL=1
```

The setting is written to `/opt/db/.env` (dated `.bak-*`), the container is created on the kept volume, so
its data and users are back, and the firewall rule and checks follow. Set `SIWO_DB_ENABLE_MYSQL=1` in your
workstation `.env` too, so `bin/siwo db engines` agrees.

## Purging the leftover volumes later

The volumes cost disk only. Once you are sure nothing in them is needed (keep a backup or a droplet snapshot):

```sh
src/shell/db/remote-run.sh --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> --no-config -- engines apply --purge --dry-run
src/shell/db/remote-run.sh --host <user>@<db-public-ip> -i ~/.ssh/<db-key> --expect-ip <db-private-ip> --no-config -- engines apply --purge
```

`--purge` backs up and then asks for a typed `DELETE-<volume>` per volume. By hand, the same is
`docker volume rm db_mysql_data db_mariadb_data` (refused while a container still uses the volume; there is
no undo).

## Reproduced in the integration test

`tests/shell/db-users-it.sh` (`ONLY=db-users-it make it`) now ends with this exact state: no `ENABLE_*` in
the `/etc`-style config, `ENABLE_MYSQL=0` in `.env`, the MySQL container removed with `docker update`,
`docker stop`, `docker rm`. It checks that the plan reports only the compose drift, that `apply` regenerates
the file with Postgres the same container (ID and start time), that the volume is kept, that a re-run of the
documented `--set` command says `nothing to change`, and that a re-enable plan writes to `.env` only.

## Lessons

- Never paste a command with `<placeholders>` into a shell; remote-run now refuses them when quoted, the shell
  fails before it when not.
- `--dry-run` before `--` connects to nothing; after the manager command it is the server-side plan.
- sudo with a password needs a terminal; remote-run probes `sudo -n true` and only then uses `ssh -t`.
- The server's live config can be `/opt/db/.env` alone; the tools now write where the key lives.
