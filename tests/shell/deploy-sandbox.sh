#!/usr/bin/env bash
# Runs ploi-deploy.sh (PRESET=generic, in-place) against a throwaway git repo.
# Needs only bash + git + GNU or BSD sed; nothing outside a temp dir is touched.
# shellcheck disable=SC2016  # sed programs insert literal $VARS on purpose
set -euo pipefail
sed --version >/dev/null 2>&1 || { echo "deploy sandbox skipped (needs GNU sed, as on the Ubuntu servers and CI)"; exit 0; }
D="$(cd "$(dirname "$0")/../.." && pwd)/shell/deploy/ploi-deploy.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/site" 2>/dev/null
(cd "$T/site" && git checkout -q -b main && printf 'GREETING=hi\n' > .env.example && git add . \
  && git -c user.email=t@t -c user.name=t commit -qm init && git push -q origin main)
S="$T/script.sh"
sed -e 's/^PRESET="laravel"/PRESET="generic"/' -e 's/^PHP_MIN="8.3.0"/PHP_MIN=""/' \
    -e 's/^INSTALL_ENV_KEYS=""/INSTALL_ENV_KEYS="ADMIN_EMAIL"/' \
    -e 's/^FIRST_INSTALL_CMD=""/FIRST_INSTALL_CMD="echo installed-by-\\$ADMIN_EMAIL > first.txt"/' \
    -e 's/^ENV_DEFAULTS=""/ENV_DEFAULTS="APP_HOST=@SITE_DOMAIN@"/' \
    -e 's/^HEALTHCHECK_CMD=""/HEALTHCHECK_CMD="test -L .env"/' \
    -e 's/^REQUIRED_VARS=""/REQUIRED_VARS="GREETING"/' "$D" > "$S"
run() { SITE_ROOT="$T/site" SHARED="$T/shared" bash "$S" >"$T/log" 2>&1; }
if run; then echo "FAIL: first run should stop for install.env"; exit 1; fi
grep -q 'First install needs: ADMIN_EMAIL' "$T/log" || { cat "$T/log"; exit 1; }
echo 'ADMIN_EMAIL=a@example.com' > "$T/shared/install.env"
run || { cat "$T/log"; exit 1; }
grep -q 'installed-by-a@example.com' "$T/site/first.txt"
[ ! -e "$T/shared/install.env" ] && [ -f "$T/shared/.first-install-done" ]
grep -q "^APP_HOST=example.com$" "$T/shared/.env"
[ "$(stat -c %a "$T/shared/.env" 2>/dev/null || stat -f %Lp "$T/shared/.env")" = 600 ]
rm "$T/site/first.txt"; run || { cat "$T/log"; exit 1; }
[ ! -e "$T/site/first.txt" ] || { echo "FAIL: first install ran twice"; exit 1; }
echo "deploy sandbox ok"
