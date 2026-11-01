#!/usr/bin/env bash
# Offline smoke tests: nothing here touches a server, Docker or the network.
# SC2015: `check && ok || fail` is the idiom here (ok never fails).
# SC2016: patterns match literal ${VAR} text in generated files.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
gen() { openssl rand -hex "${1:-12}"; }  # repo rule: test secrets are generated per run, never hardcoded
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

M=src/shell/db/docker-db-server-manager.sh
W=src/shell/web/update-env-db.sh
R=src/shell/db/remote-run.sh
D=src/shell/deploy/ploi-deploy.sh

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
OLDPW="$(gen)"; NEWPW="$(gen)"
printf 'APP_NAME=x\nDB_HOST=old\nDB_SSLMODE=prefer\nDB_PASSWORD=%s\n' "$OLDPW" > "$T/app.env"
printf '# from env\nDB_HOST=10.0.0.5\nDB_PASSWORD=%s\n' "$NEWPW" > "$T/v.env"
"$W" --env "$T/app.env" --from "$T/v.env" --set DB_PORT=5432 > "$T/out"
"$W" --env "$T/app.env" --from "$T/v.env" --set DB_PORT=5432 --no-backup > /dev/null
[ "$(grep -c '^DB_HOST=' "$T/app.env")" = 1 ] && ok "update-env-db is idempotent" || fail "update-env-db is idempotent"
grep -q '^DB_SSLMODE=prefer$' "$T/app.env" && grep -q '^APP_NAME=x$' "$T/app.env" && ok "other keys kept" || fail "other keys kept"
grep -q 'DB_PASSWORD=\*\*\*' "$T/out" && ! grep -q "$NEWPW" "$T/out" && ok "password masked in output" || fail "password masked in output"
ls "$T"/app.env.bak.* >/dev/null && ok "backup written" || fail "backup written"
if "$W" --env "$T/app.env" --set APP_KEY=x 2>/dev/null; then fail "non-DB key"; else ok "non-DB_* keys refused"; fi
for i in 1 2 3 4 5 6 7; do touch "$T/app.env.bak.2026010100000$i"; done
KEEP_BACKUPS=3 "$W" --env "$T/app.env" --set DB_PORT=6432 >/dev/null
baks=("$T"/app.env.bak.*); newest="${baks[${#baks[@]}-1]}"
[ "${#baks[@]}" = 3 ] && ok ".env backups pruned to KEEP_BACKUPS" || fail ".env backups pruned"
[ "$(stat -c %a "$newest" 2>/dev/null || stat -f %Lp "$newest")" = 600 ] \
  && ok ".env backup is chmod 600" || fail ".env backup is chmod 600"

# --- check-db-reach --------------------------------------------------------------
if src/shell/web/check-db-reach.sh 127.0.0.1 9 >/dev/null 2>&1; then fail "closed port reported open"; else ok "check-db-reach reports a closed port"; fi
CR="$(mktemp -d)"; mkdir -p "$CR/bin" "$CR/md/interfaces/private/0/ipv4"
printf nyc1 > "$CR/md/region"; printf 10.124.0.2 > "$CR/md/interfaces/private/0/ipv4/address"; printf 255.255.240.0 > "$CR/md/interfaces/private/0/ipv4/netmask"
printf '#!/bin/sh\nfor a; do u="$a"; done; cat "%s/md/${u#http://md/}"\n' "$CR" > "$CR/bin/curl"; chmod +x "$CR/bin/curl"
PATH="$CR/bin:$PATH" METADATA_URL=http://md src/shell/web/check-db-reach.sh --db-region ams3 10.110.0.5 9 > "$CR/o" 2>&1 || true
grep -q 'region nyc1' "$CR/o" && grep -q 'the DB is in ams3' "$CR/o" && grep -q 'outside this droplet.s VPC' "$CR/o" \
  && ok "check-db-reach warns on a region mismatch and a private IP outside the VPC" || { cat "$CR/o"; fail "check-db-reach region"; }
PATH="$CR/bin:$PATH" METADATA_URL=http://md src/shell/web/check-db-reach.sh 10.124.0.9 9 > "$CR/o" 2>&1 || true
! grep -q WARNING "$CR/o" && ok "check-db-reach: same VPC, no warning" || { cat "$CR/o"; fail "same vpc"; }
rm -rf "$CR"

# --- adminer toggle + tunnel helper ----------------------------------------------
grep -q 'adminer:' "$T/e1000/docker-compose.yml" && fail "adminer on by default" || ok "adminer off by default"
mkdir -p "$T/adm"; PRIVATE_IP=10.0.0.5 DB_DIR="$T/adm" ENABLE_ADMINER=1 \
  bash -c 'source <(sed "/^# ---- main/,\$d" "$1"); dc() { :; }; write_files >/dev/null' _ "$M"
grep -qF '"127.0.0.1:${ADMINER_PORT}:8080"' "$T/adm/docker-compose.yml" && ! grep -q 'PRIVATE_IP}:${ADMINER' "$T/adm/docker-compose.yml" \
  && ok "adminer binds to 127.0.0.1 only" || fail "adminer binds to 127.0.0.1 only"
grep -Eq '^ADMINER_IMAGE=adminer:[0-9]+\.[0-9]+\.[0-9]+' "$T/adm/stack.env" && ok "adminer image is pinned" || fail "adminer image is pinned"
grep -q 'AUTH_USER: ${PGBOUNCER_AUTH_USER}' "$T/adm/docker-compose.yml" && grep -q 'pgbouncer.get_auth' "$T/adm/docker-compose.yml" \
  && ok "pgbouncer: dedicated auth_user + auth_query function" || fail "pgbouncer auth_user"
for c in "create-user x" "grant 'a;b' db" "drop-db postgres" "drop-user root mysql" "create-db shop --extensions 'x;y'"; do
  if eval "PRIVATE_IP=10.0.0.5 \"\$M\" $c" >/dev/null 2>&1; then fail "unsafe args accepted: $c"; fi
done; ok "user commands reject unsafe/protected args"
TN=src/shell/tunnels/db-tunnel.sh
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

# --- remote-run snapshot fallback chain (PATH stubs: ssh, scp, doctl, workbench) ---
SB="$T/stubs"; mkdir -p "$SB"; L="$T/stub.log"
printf '#!/usr/bin/env bash\ncase "$*" in *metadata/v1/id*) echo 123456 ;; *) echo "ssh $*" >> "%s" ;; esac\n' "$L" > "$SB/ssh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/scp"
printf '#!/usr/bin/env bash\ncase "$*" in "account get") [ "${STUB_DOCTL:-0}" = 1 ] ;; *) echo "doctl $*" >> "%s" ;; esac\n' "$L" > "$SB/doctl"
printf '#!/usr/bin/env bash\ncase "$*" in "digitalocean account --json") [ "${STUB_WB:-0}" = 1 ] ;; *) echo "workbench $*" >> "%s" ;; esac\n' "$L" > "$SB/workbench"
chmod +x "$SB"/*
rr() { : > "$L"; PATH="$SB:$PATH" WORKBENCH="$SB/workbench" "$R" --host h --expect-ip 10.0.0.5 "$@" </dev/null > "$T/rr.out" 2>&1; }
STUB_DOCTL=1 STUB_WB=1 rr -- upgrade
grep -q 'doctl compute droplet-action snapshot 123456 --snapshot-name db-pre-upgrade-' "$L" && grep -q 'upgrade --snapshot-taken' "$L" && ! grep -q '^workbench' "$L" \
  && ok "snapshot chain 1: doctl first, then --snapshot-taken" || fail "snapshot chain doctl: $(cat "$L" "$T/rr.out")"
STUB_DOCTL=0 STUB_WB=1 rr -- upgrade
grep -q 'workbench digitalocean snapshot 123456 --name db-pre-upgrade-.* --wait --yes' "$L" && grep -q 'upgrade --snapshot-taken' "$L" && ! grep -q '^doctl' "$L" \
  && ok "snapshot chain 2: bin/workbench when doctl is not set up" || fail "snapshot chain workbench: $(cat "$L" "$T/rr.out")"
STUB_DOCTL=0 STUB_WB=0 rr -- upgrade
grep -q 'the server will use its own token' "$T/rr.out" && grep -q 'docker-db-server-manager.sh upgrade$' "$L" && ! grep -qE '^(doctl|workbench) ' "$L" \
  && ok "snapshot chain 3/4: falls through to the server (token there, or typed CONTINUE)" || fail "snapshot chain server: $(cat "$L" "$T/rr.out")"
set +e; STUB_DOCTL=0 STUB_WB=0 rr --snapshot-with none -- upgrade; rc=$?; set -e
[ "$rc" -ne 0 ] && grep -q 'not confirmed; nothing changed' "$T/rr.out" && [ ! -s "$L" ] \
  && ok "snapshot skip needs explicit confirmation" || fail "snapshot skip: rc=$rc $(cat "$T/rr.out")"
set +e; STUB_DOCTL=0 rr --snapshot-with doctl -- upgrade; rc=$?; set -e
[ "$rc" -ne 0 ] && grep -q 'doctl is missing or not authenticated' "$T/rr.out" && ok "--snapshot-with doctl fails fast" || fail "--snapshot-with doctl"
STUB_DOCTL=1 rr -- upgrade --no-snapshot
! grep -q '^doctl' "$L" && grep -q 'upgrade --no-snapshot' "$L" && ok "an explicit snapshot flag skips the chain" || fail "explicit flag"
STUB_DOCTL=1 rr -- verify
! grep -q '^doctl' "$L" && ok "no snapshot offer for non-upgrade commands" || fail "non-upgrade snapshot"
STUB_DOCTL=1 rr -- env-apply, pg-major-upgrade --to 19 --dry-run
! grep -q '^doctl' "$L" && ! grep -q 'snapshot-taken' "$L" \
  && ok "env-apply / pg-major-upgrade are not mistaken for upgrade" || fail "substring upgrade match: $(cat "$L")"
STUB_DOCTL=1 rr -- env-apply, upgrade
grep -q 'env-apply$' "$L" && grep -q 'upgrade --snapshot-taken' "$L" \
  && ok "the snapshot flag goes to the upgrade command, not the first match" || fail "flag placement: $(cat "$L")"
printf '#!/usr/bin/env bash\necho "scp $*" >> "%s"\n' "$L" > "$SB/scp"; chmod +x "$SB/scp"
: > "$T/c.conf"; rr --no-upload --config "$T/c.conf" -- verify
grep -q "scp -q $T/c.conf h:.vsw-upload-docker-db-server-manager.conf" "$L" && ! grep -q 'docker-db-server-manager.sh h:' "$L" \
  && ok "--no-upload still uploads --config (no stale config installed)" || fail "--no-upload --config: $(cat "$L")"

# --- deploy script: no Ploi placeholder collisions ---------------------------
if grep -nE '\$\{(BRANCH|SITE|RELEASE|DOMAIN|REPOSITORY|REPOSITORY_NAME|PROJECT_ROOT|TIME)\}' "$D"; then
  fail "deploy script uses a Ploi placeholder name as a shell variable"
fi
ok "deploy script avoids Ploi placeholder names"

# --- deploy script sandbox (generic preset, hooks, first-install marker) -----
bash tests/shell/deploy-sandbox.sh | grep -qE 'deploy sandbox (ok|skipped)' && ok "deploy sandbox" || fail "deploy sandbox"

# --- bin/workbench dispatcher ------------------------------------------------------
grep -q 'src/shell/db/remote-run.sh' <<<"$(bin/workbench list)" && ok "workbench list" || fail "workbench list"
bin/workbench db remote-run --dry-run --host h --expect-ip 10.0.0.5 -- env | grep 'docker-db-server-manager.sh env' >/dev/null \
  && ok "workbench <area> <tool> runs shell tools" || fail "workbench <area> <tool>"
if bin/workbench 'db;id' x 2>/dev/null || bin/workbench db ../../etc 2>/dev/null; then fail "workbench accepted a bad tool name"; fi
ok "workbench rejects bad area/tool names"
[ ! -e scripts ] && [ ! -e tools ] && [ ! -e bin/vsw ] && ok "no legacy scripts/, tools/ or bin/vsw" || fail "legacy paths are back"
if command -v python3 >/dev/null 2>&1; then
  set +e; bin/workbench py ping 127.0.0.1 notaport >/dev/null 2>&1; rc=$?; set -e; [ "$rc" -eq 2 ] && ok "workbench py validates input" || fail "workbench py validation"
fi
if command -v php >/dev/null 2>&1 && php -r 'exit(PHP_VERSION_ID >= 80400 ? 0 : 1);' && [ -f src/php/vendor/autoload.php ]; then
  out="$(DIGITALOCEAN_TOKEN="$(gen)" VSW_AUDIT_LOG=off bin/workbench digitalocean snapshot 42 --name pre-upgrade --dry-run)"
  grep -q 'DRY RUN — nothing sent.*POST /v2/droplets/42/actions' <<<"$out" && ok "workbench do snapshot --dry-run sends nothing" || fail "do snapshot dry-run: $out"
  set +e; DIGITALOCEAN_TOKEN="$(gen)" VSW_AUDIT_LOG=off bin/workbench digitalocean snapshot 42 </dev/null 2>/dev/null; rc=$?; set -e
  [ "$rc" -eq 3 ] && ok "workbench writes refuse without --yes" || fail "write without --yes exit $rc"
  set +e; env -u DIGITALOCEAN_TOKEN VSW_CREDENTIALS_FILE=/nonexistent bin/workbench digitalocean droplets 2>"$T/cred"; rc=$?; set -e
  [ "$rc" -eq 4 ] && grep -q 'DIGITALOCEAN_TOKEN is not set' "$T/cred" && ok "workbench reports missing credentials" || fail "missing credentials exit $rc"
else
  ok "workbench PHP checks skipped (php 8.4+ with src/php/vendor not available)"
fi

# --- no client data in tracked files -------------------------------------------
if tests/shell/client-check.sh >"$T/cc" 2>&1; then ok "no client identifiers in tracked files ($(tail -1 "$T/cc"))"
else cat "$T/cc"; fail "client identifiers in tracked files"; fi

# --- no secrets committed -----------------------------------------------------
if git ls-files >/dev/null 2>&1; then files="$(git ls-files)"; else files="$(find . -type f -not -path './.git/*')"; fi
# shellcheck disable=SC2086
if grep -nE 'PASSWORD=[0-9a-f]{24,}' $files; then fail "hex password value found"; fi
ok "no generated passwords in tracked files"

echo "all $pass checks passed"
