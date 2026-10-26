#!/usr/bin/env bash
# Offline smoke tests: nothing here touches a server, Docker or the network.
# SC2015: `check && ok || fail` is the idiom here (ok never fails).
# SC2016: patterns match literal ${VAR} text in generated files.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

M=scripts/db/docker-db-server-manager.sh
W=scripts/web/update-env-db.sh
R=scripts/db/remote-run.sh
D=scripts/deploy/ploi-deploy.sh

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

# --- remote-run -------------------------------------------------------------
"$R" --dry-run --host h --expect-ip 10.0.0.5 -- verify, env | grep 'sudo /root/docker-db-server-manager.sh env' >/dev/null \
  && ok "remote-run builds the command list" || fail "remote-run builds the command list"
"$R" --dry-run --host h --expect-ip 10.0.0.5 | grep -F "inet 10\\.0\\.0\\.5/" >/dev/null && ok "remote-run includes IP guard" || fail "remote-run includes IP guard"

# --- deploy script: no Ploi placeholder collisions ---------------------------
if grep -nE '\$\{(BRANCH|SITE|RELEASE|DOMAIN|REPOSITORY|REPOSITORY_NAME|PROJECT_ROOT|TIME)\}' "$D"; then
  fail "deploy script uses a Ploi placeholder name as a shell variable"
fi
ok "deploy script avoids Ploi placeholder names"

# --- no secrets committed -----------------------------------------------------
if git ls-files >/dev/null 2>&1; then files="$(git ls-files)"; else files="$(find . -type f -not -path './.git/*')"; fi
# shellcheck disable=SC2086
if grep -nE 'PASSWORD=[0-9a-f]{24,}' $files; then fail "hex password value found"; fi
ok "no generated passwords in tracked files"

echo "all $pass checks passed"
