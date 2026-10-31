#!/usr/bin/env bash
# Offline smoke tests: nothing here touches a server, Docker or the network.
# SC2015: `check && ok || fail` is the idiom here (ok never fails).
# SC2016: patterns match literal ${VAR} text in generated files.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

M=shell/db/docker-db-server-manager.sh
W=shell/web/update-env-db.sh
R=shell/db/remote-run.sh
D=shell/deploy/ploi-deploy.sh

# --- manager ---------------------------------------------------------------
"$M" --version | grep -q 'Docker DB Server Setup Manager' && ok "manager --version" || fail "manager --version"
"$M" help | grep -q 'cron-install' && ok "manager help" || fail "manager help"
printf 'PG_USER="cfguser"\nPG_DB=cfgdb   # comment\nKEEP=3\n' > "$T/c.conf"
out="$(KEEP=9 bash -c 'source <(sed -n "1,/^SELF=/p" "$1"); echo "$PG_USER $PG_DB $KEEP"' _ "$M" --config "$T/c.conf")"
[ "$out" = "cfguser cfgdb 9" ] && ok "config file fills defaults, env wins" || fail "config precedence: $out"
if "$M" status --config "$T/missing.conf" 2>/dev/null; then fail "missing --config accepted"; else ok "missing --config rejected"; fi
if EXPECTED_PRIVATE_IP=192.0.2.123 "$M" status 2>"$T/err"; then fail "guard"; fi
grep -q 'wrong server' "$T/err" && ok "EXPECTED_PRIVATE_IP guard aborts" || fail "EXPECTED_PRIVATE_IP guard aborts"
mkdir -p "$T/db"
PRIVATE_IP=10.0.0.5 DB_DIR="$T/db" PG_USER=u1 PG_DB=d1 MYSQL_PORT=13306 \
  bash -c 'source <(sed "/^# ---- main/,\$d" "$1"); docker() { :; }; write_files >/dev/null' _ "$M"
grep -q '^\\c d1$' "$T/db/postgres/init/10-extensions.sql" && ok "init SQL uses PG_DB" || fail "init SQL uses PG_DB"
grep -q '^MYSQL_PORT=13306$' "$T/db/stack.env" && ok "stack.env carries settings" || fail "stack.env carries settings"
grep -q '${PRIVATE_IP}:${MYSQL_PORT}:3306' "$T/db/docker-compose.yml" && ok "compose uses port variables" || fail "compose uses port variables"

for combo in "1 0 0 0" "0 0 1 1"; do
  read -r ep eb em ea <<<"$combo"; d="$T/e$ep$eb$em$ea"; mkdir -p "$d"
  PRIVATE_IP=10.0.0.5 DB_DIR="$d" ENABLE_POSTGRES=$ep ENABLE_PGBOUNCER=$eb ENABLE_MYSQL=$em ENABLE_MARIADB=$ea \
    bash -c 'source <(sed "/^# ---- main/,\$d" "$1"); dc() { :; }; write_files >/dev/null; enabled_ports | tr "\n" " "' _ "$M" > "$d/ports"
done
grep -q '^  postgres:' "$T/e1000/docker-compose.yml" && ! grep -qE '^  (mysql|mariadb|pgbouncer):' "$T/e1000/docker-compose.yml" \
  && [ "$(cat "$T/e1000/ports")" = "5432 " ] && ok "engine toggles: postgres only" || fail "engine toggles: postgres only"
! grep -qE '^  (postgres|pgbouncer):' "$T/e0011/docker-compose.yml" && grep -q '^  mariadb:' "$T/e0011/docker-compose.yml" \
  && [ "$(cat "$T/e0011/ports")" = "3306 3307 " ] && ok "engine toggles: mysql + mariadb" || fail "engine toggles: mysql + mariadb"
if ENABLE_POSTGRES=0 PRIVATE_IP=10.0.0.5 "$M" status 2>"$T/err"; then fail "pgbouncer without postgres"; fi
grep -q 'needs ENABLE_POSTGRES=1' "$T/err" && ok "pgbouncer without postgres rejected" || fail "pgbouncer without postgres rejected"
PG_EXTENSIONS="vector pg_trgm" PRIVATE_IP=10.0.0.5 DB_DIR="$T/x" bash -c 'mkdir -p "$2"; source <(sed "/^# ---- main/,\$d" "$1"); dc() { :; }; write_files >/dev/null' _ "$M" "$T/x"
[ "$(grep -c 'CREATE EXTENSION' "$T/x/postgres/init/10-extensions.sql")" = 4 ] && ok "PG_EXTENSIONS drives the init SQL" || fail "PG_EXTENSIONS drives the init SQL"
"$M" init "$T/init.conf" >/dev/null 2>&1; grep -q '^ENABLE_MYSQL=1$' "$T/init.conf" && ! grep -qi password "$T/init.conf" \
  && ok "init writes a config without secrets" || fail "init writes a config without secrets"
if PRIVATE_IP=10.0.0.5 "$M" create-db 'bad;name' 2>/dev/null; then fail "create-db name"; else ok "create-db rejects unsafe names"; fi

# --- update-env-db ----------------------------------------------------------
printf 'APP_NAME=x\nDB_HOST=old\nDB_SSLMODE=prefer\nDB_PASSWORD=old\n' > "$T/app.env"
printf '# from env\nDB_HOST=10.0.0.5\nDB_PASSWORD=s3cret\n' > "$T/v.env"
"$W" --env "$T/app.env" --from "$T/v.env" --set DB_PORT=5432 > "$T/out"
"$W" --env "$T/app.env" --from "$T/v.env" --set DB_PORT=5432 --no-backup > /dev/null
[ "$(grep -c '^DB_HOST=' "$T/app.env")" = 1 ] && ok "update-env-db is idempotent" || fail "update-env-db is idempotent"
grep -q '^DB_SSLMODE=prefer$' "$T/app.env" && grep -q '^APP_NAME=x$' "$T/app.env" && ok "other keys kept" || fail "other keys kept"
grep -q 'DB_PASSWORD=\*\*\*' "$T/out" && ! grep -q s3cret "$T/out" && ok "password masked in output" || fail "password masked in output"
ls "$T"/app.env.bak.* >/dev/null && ok "backup written" || fail "backup written"
if "$W" --env "$T/app.env" --set APP_KEY=x 2>/dev/null; then fail "non-DB key"; else ok "non-DB_* keys refused"; fi
for i in 1 2 3 4 5 6 7; do touch "$T/app.env.bak.2026010100000$i"; done
KEEP_BACKUPS=3 "$W" --env "$T/app.env" --set DB_PORT=6432 >/dev/null
baks=("$T"/app.env.bak.*); newest="${baks[${#baks[@]}-1]}"
[ "${#baks[@]}" = 3 ] && ok ".env backups pruned to KEEP_BACKUPS" || fail ".env backups pruned"
[ "$(stat -c %a "$newest" 2>/dev/null || stat -f %Lp "$newest")" = 600 ] \
  && ok ".env backup is chmod 600" || fail ".env backup is chmod 600"

# --- check-db-reach --------------------------------------------------------------
if shell/web/check-db-reach.sh 127.0.0.1 9 >/dev/null 2>&1; then fail "closed port reported open"; else ok "check-db-reach reports a closed port"; fi

# --- adminer toggle + tunnel helper ----------------------------------------------
grep -q 'adminer:' "$T/e1000/docker-compose.yml" && fail "adminer on by default" || ok "adminer off by default"
mkdir -p "$T/adm"; PRIVATE_IP=10.0.0.5 DB_DIR="$T/adm" ENABLE_ADMINER=1 \
  bash -c 'source <(sed "/^# ---- main/,\$d" "$1"); dc() { :; }; write_files >/dev/null' _ "$M"
grep -qF '"127.0.0.1:${ADMINER_PORT}:8080"' "$T/adm/docker-compose.yml" && ! grep -q 'PRIVATE_IP}:${ADMINER' "$T/adm/docker-compose.yml" \
  && ok "adminer binds to 127.0.0.1 only" || fail "adminer binds to 127.0.0.1 only"
grep -Eq '^ADMINER_IMAGE=adminer:[0-9]+\.[0-9]+\.[0-9]+' "$T/adm/stack.env" && ok "adminer image is pinned" || fail "adminer image is pinned"
grep -q 'AUTH_USER: ${PG_USER}' "$T/adm/docker-compose.yml" && ok "pgbouncer auth_user set (create-db users pool)" || fail "pgbouncer auth_user"
for c in "create-user x" "grant 'a;b' db" "drop-db postgres" "drop-user root mysql" "create-db shop --extensions 'x;y'"; do
  if eval "PRIVATE_IP=10.0.0.5 \"\$M\" $c" >/dev/null 2>&1; then fail "unsafe args accepted: $c"; fi
done; ok "user commands reject unsafe/protected args"
TN=shell/tunnels/db-tunnel.sh
"$TN" --print --host u@h --private-ip 10.0.0.5 mysql mariadb adminer | grep -q '127.0.0.1:13306:10.0.0.5:3306 -L 127.0.0.1:13307:10.0.0.5:3307 -L 127.0.0.1:8081:127.0.0.1:8081 u@h' \
  && ok "db-tunnel builds forwards" || fail "db-tunnel builds forwards"
if "$TN" --print --host u@h postgres 2>/dev/null; then fail "db-tunnel without private ip"; else ok "db-tunnel needs --private-ip for engines"; fi

# --- guided upgrade (offline parts) -------------------------------------------
"$M" help | grep -q 'upgrade' && ok "help mentions upgrade" || fail "help mentions upgrade"
src='source <(sed "/^# ---- main/,\$d" "$1"); shift'
if PRIVATE_IP=999.1.1.1 bash -c "$src; validate_config" _ "$M" 2>"$T/v1"; then fail "bad ip accepted"; fi
grep -q 'not an IPv4' "$T/v1" && ok "validate_config rejects a bad IP" || fail "validate_config bad ip"
if PRIVATE_IP=10.0.0.5 PG_PORT=3306 MYSQL_PORT=3306 ENABLE_MYSQL=1 bash -c "$src; validate_config" _ "$M" 2>"$T/v2"; then fail "dup port accepted"; fi
grep -q 'used twice' "$T/v2" && ok "validate_config rejects duplicate ports" || fail "validate_config dup port"
PRIVATE_IP=10.0.0.5 bash -c "$src; validate_config" _ "$M" >/dev/null 2>&1 && ok "validate_config accepts defaults" || fail "validate_config defaults"
sleep 30 & h=$!; mkdir "$T/lk"; echo "$h" > "$T/lk/pid"
if DBM_LOCK="$T/lk" bash -c "$src; take_lock" _ "$M" 2>"$T/l"; then fail "lock ignored"; fi
kill "$h" 2>/dev/null; wait "$h" 2>/dev/null || true
grep -q 'another run is in progress' "$T/l" && ok "lock conflict refused" || fail "lock conflict"
if NONINTERACTIVE=1 SNAP_MODE=ask bash -c "$src; snapshot_policy_check" _ "$M" </dev/null 2>"$T/n"; then fail "ni snapshot"; fi
grep -q 'no-snapshot' "$T/n" && ok "non-interactive needs a snapshot decision" || fail "non-interactive snapshot"
"$R" --dry-run --host h --expect-ip 10.0.0.5 -- upgrade --dry-run | grep 'docker-db-server-manager.sh.prev' >/dev/null \
  && ok "remote-run keeps the previous manager" || fail "remote-run .prev"

# --- remote-run -------------------------------------------------------------
"$R" --dry-run --host h --expect-ip 10.0.0.5 -- verify, env | grep 'sudo /root/docker-db-server-manager.sh env' >/dev/null \
  && ok "remote-run builds the command list" || fail "remote-run builds the command list"
"$R" --dry-run --host h --expect-ip 10.0.0.5 | grep -F "inet 10\\.0\\.0\\.5/" >/dev/null && ok "remote-run includes IP guard" || fail "remote-run includes IP guard"

# --- deploy script: no Ploi placeholder collisions ---------------------------
if grep -nE '\$\{(BRANCH|SITE|RELEASE|DOMAIN|REPOSITORY|REPOSITORY_NAME|PROJECT_ROOT|TIME)\}' "$D"; then
  fail "deploy script uses a Ploi placeholder name as a shell variable"
fi
ok "deploy script avoids Ploi placeholder names"

# --- deploy script sandbox (generic preset, hooks, first-install marker) -----
bash tests/shell/deploy-sandbox.sh | grep -qE 'deploy sandbox (ok|skipped)' && ok "deploy sandbox" || fail "deploy sandbox"

# --- core stays project-neutral -------------------------------------------------
if git ls-files >/dev/null 2>&1; then core="$(git ls-files | grep -vE '^(examples/|CHANGELOG\.md$|tests/shell/smoke\.sh$)')"
else core="$(find . -type f -not -path './.git/*' -not -path './examples/*' -not -name CHANGELOG.md -not -name smoke.sh)"; fi
# shellcheck disable=SC2086
if grep -il 'myapp' $core; then fail "project name in core files (only examples/ may name a project)"
else ok "core is project-neutral (no project names outside examples/)"; fi

# --- no secrets committed -----------------------------------------------------
if git ls-files >/dev/null 2>&1; then files="$(git ls-files)"; else files="$(find . -type f -not -path './.git/*')"; fi
# shellcheck disable=SC2086
if grep -nE 'PASSWORD=[0-9a-f]{24,}' $files; then fail "hex password value found"; fi
ok "no generated passwords in tracked files"

echo "all $pass checks passed"
