#!/usr/bin/env bash
# Offline tests for the server tools (server/*, web/diagnose, ssh/fixkeys): a fake root
# (VSW_SYSROOT) and stub commands on PATH; nothing touches this machine's /etc or the network.
# shellcheck disable=SC2015,SC2016  # stub bodies are literal shell
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
stub() { printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n%s\n' "$1" "$T" "${2:-}" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
fresh() { rm -rf "$T/root" "$T/calls"; mkdir -p "$T/root/root/.ssh" "$T/root/etc/ssh" "$T/root/var/run"; : > "$T/calls"; }
mkdir -p "$T/bin"
for c in systemctl apt-get sysctl sshd dpkg-query apt-mark shutdown ufw php; do stub "$c"; done
stub nc 'exit 1'
stub apt "printf 'Listing...\nopenssl/noble-updates 3.0.13 amd64 [upgradable from: 3.0.12]\ndocker-ce/noble 5:28 amd64 [upgradable from: 5:27]\n'"
stub docker 'case "$1" in ps) [ "$2" = -q ] && echo c0ffee || echo "10.0.0.5:5432->5432/tcp";; esac'
export PATH="$T/bin:$PATH" VSW_SYSROOT="$T/root" VSW_TTY="$T/tty" VSW_LOG_DIR="$T/log"
H=src/shell/server/harden.sh U=src/shell/server/update.sh W=src/shell/web/diagnose.sh
: > "$T/tty"

# --- harden ---------------------------------------------------------------------
fresh
if bash "$H" --only ssh >"$T/o" 2>&1; then fail "harden without keys"; fi
grep -q 'lockout guard' "$T/o" && ok "harden: refuses ssh lockdown when no authorized key exists" || fail "lockout guard"
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly test@x' > "$T/root/root/.ssh/authorized_keys"
echo 'Include /etc/ssh/sshd_config.d/*.conf' > "$T/root/etc/ssh/sshd_config"
bash "$H" >"$T/o" 2>&1 || true
[ ! -e "$T/root/etc/ssh/sshd_config.d" ] && grep -q 'Type yes' "$T/o" && ok "harden: plan + prompt, nothing written without yes" || fail "harden plan"
if bash "$H" --check >/dev/null 2>&1; then fail "--check with pending"; else ok "harden --check exits 1 when changes are pending"; fi
bash "$H" --yes >/dev/null
grep -q '^PasswordAuthentication no' "$T/root/etc/ssh/sshd_config.d/10-workbench.conf" && grep -q 'sshd -t' "$T/calls" && grep -q 'systemctl reload ssh' "$T/calls" \
  && ok "harden --yes: drop-in written, sshd -t, reload" || fail "harden apply"
grep -q 'outcome=succeeded' "$T/log/audit.log" && ok "harden: audit log" || fail "harden audit"
bash "$H" --check --only ssh,sysctl,journald >/dev/null && ok "harden: rerun is a no-op" || fail "harden idempotent"
fresh; echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly t' > "$T/root/root/.ssh/authorized_keys"
stub sshd 'exit 1'
bash "$H" --yes --only ssh >/dev/null 2>&1 && fail "sshd -t failure ignored" || true
[ ! -f "$T/root/etc/ssh/sshd_config.d/10-workbench.conf" ] && ! grep -q 'reload' "$T/calls" && ok "harden: sshd -t failure rolls back, no reload" || fail "sshd rollback"
stub sshd
mkdir -p "$T/root/home/ploi"; bash "$H" --firewall --only firewall >"$T/o"
grep -q 'Ploi server - skipped' "$T/o" && ok "harden: firewall left to Ploi on a Ploi server" || fail "ploi firewall"
bash "$H" --role mail >/dev/null 2>&1 && fail "bad role" || ok "harden: validates --role"

# --- update -------------------------------------------------------------------------
fresh
bash "$U" --dry-run >"$T/o"; grep -q '2 upgradable' "$T/o" && grep -q 'held for this run' "$T/o" && ! grep -q 'upgrade$' "$T/calls" \
  && ok "update: plan lists packages, holds Docker with running containers" || fail "update plan"
touch "$T/root/var/run/reboot-required"
VSW_NOW=03:10 bash "$U" --yes --reboot-window 02:00-04:00 >/dev/null
grep -q 'apt-mark hold docker-ce' "$T/calls" && grep -q 'apt-mark unhold docker-ce' "$T/calls" && grep -q 'shutdown -r +1' "$T/calls" \
  && ok "update: inside the window -> upgrade, unhold, reboot in 1 min" || fail "update in window"
: > "$T/calls"; VSW_NOW=12:00 bash "$U" --yes --reboot-window 23:30-01:00 --allow-docker >/dev/null
grep -q 'shutdown -r 23:30' "$T/calls" && ! grep -q 'apt-mark hold' "$T/calls" && ok "update: outside a midnight-crossing window -> scheduled; --allow-docker" || fail "update outside"
: > "$T/calls"; VSW_NOW=00:30 bash "$U" --yes --reboot-window 23:30-01:00 >/dev/null; grep -q 'shutdown -r +1' "$T/calls" && ok "update: 00:30 is inside 23:30-01:00" || fail "midnight"
: > "$T/calls"; bash "$U" --yes --no-reboot >"$T/o"; ! grep -q shutdown "$T/calls" && grep -q 'reboot required' "$T/o" && ok "update --no-reboot only reports" || fail "no-reboot"
bash "$U" --reboot-window 25:00-01:00 >/dev/null 2>&1 && fail "bad window" || ok "update: validates the window"
if bash "$U" >/dev/null 2>&1; then fail "update without yes"; else ok "update: not confirmed without --yes (exit 3)"; fi

# --- web diagnose -----------------------------------------------------------------------
fresh; A="$T/root/home/ploi/app.example.com"; mkdir -p "$A/storage/logs" "$A/storage/app/public" "$A/bootstrap/cache" "$A/public"; touch "$A/artisan"
printf 'APP_ENV=production\nAPP_DEBUG=true\nAPP_KEY=base64:test\nAPP_URL=https://app.example.com\nDB_CONNECTION=pgsql\nDB_HOST=203.0.113.9\nDB_PORT=6432\nDB_USERNAME=app\nDB_PASSWORD=not-a-real-password\n' > "$A/.env"; chmod 644 "$A/.env"
if bash "$W" --site app.example.com >"$T/o" 2>&1; then fail "diagnose should fail"; fi
grep -q 'FAIL  APP_DEBUG=true on prd' "$T/o" && grep -q 'not reachable' "$T/o" && grep -q 'not a private address' "$T/o" && grep -q 'fixable with --fix: env_mode debug_off storage_link' "$T/o" \
  && ok "diagnose: finds debug on prd, unreachable/public DB, fixables" || { cat "$T/o"; fail "diagnose findings"; }
! grep -q 'not-a-real-password' "$T/o" && ok "diagnose: never prints .env values" || fail "diagnose leaked"
bash "$W" --site app.example.com --fix --dry-run >/dev/null; grep -q 'APP_DEBUG=true' "$A/.env" && ok "diagnose --fix --dry-run changes nothing" || fail "dry-run"
echo yes > "$T/tty"; bash "$W" --site app.example.com --fix --yes >/dev/null 2>&1 && fail "prd fix with --yes"
grep -q 'APP_DEBUG=true' "$A/.env" && ok "diagnose: prd --fix ignores --yes and needs the typed domain" || fail "prd typed"
echo app.example.com > "$T/tty"; bash "$W" --site app.example.com --fix >/dev/null
grep -q 'APP_DEBUG=false' "$A/.env" && ls "$A"/.env.bak.* >/dev/null && grep -q 'artisan storage:link' "$T/calls" && grep -q 'fix=debug_off' "$T/log/audit.log" \
  && ok "diagnose --fix: debug off (backup), storage:link, audited" || fail "diagnose fix"
sed -i.x 's/APP_ENV=production/APP_ENV=local/; s/APP_DEBUG=false/APP_DEBUG=true/' "$A/.env"; : > "$T/tty"
bash "$W" --site app.example.com --env dev >"$T/o" 2>&1 || true; grep -q 'ok    APP_DEBUG=true' "$T/o" && ok "diagnose: APP_DEBUG allowed in dev" || fail "dev debug"
bash "$W" --site 'bad site' >/dev/null 2>&1 && fail "bad site" || ok "diagnose: validates --site"

printf '\nsmoke-server: %d passed, 0 failed\n' "$pass"
