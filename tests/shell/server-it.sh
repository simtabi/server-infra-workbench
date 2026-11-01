#!/usr/bin/env bash
# Integration test of the server tools in a throwaway Ubuntu container (Docker/OrbStack): 26.04 by default, the
# droplet-create default; SERVER_IT_IMAGE=ubuntu:24.04 for servers still on the previous LTS.
# Not part of `make ci` (needs Docker and the Ubuntu mirrors, ~3 min): run by `make it`.
# Real apt, real sshd -t / sshd -T, real files; no systemd in a container, so service reloads only warn.
# Not covered here (offline in smoke-server.sh): swap (swapon needs privileges), Docker install, --host.
# shellcheck disable=SC2015  # guard idiom
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "server-it skipped (no docker)"; exit 0; }
IMG="${SERVER_IT_IMAGE:-ubuntu:26.04}" NAME="vsw-server-it-$$"
OS_VER="${IMG##*:}"; [[ "$OS_VER" =~ ^[0-9]{2}\.[0-9]{2}$ ]] || OS_VER=""  # inventory checks "Ubuntu <tag>" for a numeric tag
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$NAME" -v "$PWD/src/shell:/w/src/shell:ro" -v "$PWD/config:/w/config:ro" "$IMG" sleep infinity >/dev/null
docker exec -i -e OS_VER="$OS_VER" "$NAME" bash -s <<'INNER'
set -euo pipefail
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq openssh-server tzdata openssl >/dev/null
mkdir -p /run/sshd /root/.ssh; echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly it@test' > /root/.ssh/authorized_keys
S=/w/src/shell; echo yes > /tmp/tty; export SIW_TTY=/tmp/tty

# init: plan, then apply (no swap in a container, harden runs as part of init)
bash $S/server/init.sh --role base --swap 0 --dry-run > /tmp/o
grep -q 'todo  packages' /tmp/o && grep -q 'todo  harden' /tmp/o && [ ! -f /etc/ssh/sshd_config.d/10-workbench.conf ] && ok "init --dry-run: plan only" || { cat /tmp/o; fail "init plan"; }
bash $S/server/init.sh --role base --swap 0 --timezone Europe/London > /tmp/o 2>&1 || { cat /tmp/o; fail "init apply"; }
[ "$(cat /etc/timezone)" = Europe/London ] && command -v jq >/dev/null && ok "init: timezone (no systemd fallback) and base packages" || fail "init tz/packages"
# capture, then grep: `sshd -T | grep -q` under pipefail fails when grep exits first and sshd gets SIGPIPE.
# OpenSSH 9 (24.04) prints prohibit-password as its old alias without-password; OpenSSH 10 (26.04) prints prohibit-password.
sshd -t && T="$(sshd -T 2>/dev/null)" && grep -qx 'passwordauthentication no' <<<"$T" && grep -qxE 'permitrootlogin (without|prohibit)-password' <<<"$T" \
  && ok "init -> harden: real sshd -T shows keys only, root by key" \
  || { echo "--- sshd -t:"; sshd -t || true; echo "--- sshd -T (auth lines):"; sshd -T 2>&1 | grep -iE "passwordauth|permitroot|error|fatal|bad|unsupported" || true; ls -la /etc/ssh/sshd_config.d/ /etc/ssh/ | grep -E "key|conf"; fail "sshd -T"; }
[ -f /etc/fail2ban/jail.d/workbench-sshd.local ] && dpkg -s fail2ban unattended-upgrades >/dev/null 2>&1 && ok "harden: fail2ban + unattended-upgrades installed for real" || fail "harden pkgs"
grep -q 'tool=init .*outcome=succeeded' /var/log/server-infra-workbench/audit.log && grep -q 'tool=harden .*outcome=succeeded' /var/log/server-infra-workbench/audit.log && ok "audit: init and harden logged" || fail "audit"
bash $S/server/init.sh --role base --swap 0 --timezone Europe/London > /tmp/o 2>&1; grep -q 'nothing to change' /tmp/o && ok "init: rerun is a no-op" || { cat /tmp/o; fail "init rerun"; }
bash $S/server/harden.sh --check >/dev/null && ok "harden --check: clean after init" || fail "harden check"

# a broken sshd drop-in is rolled back
printf 'Bogus yes\n' > /etc/ssh/sshd_config.d/00-broken.conf; rm /etc/ssh/sshd_config.d/10-workbench.conf
bash $S/server/harden.sh --only ssh --yes >/dev/null 2>&1 && fail "should fail with a broken sshd config" || true
[ ! -f /etc/ssh/sshd_config.d/10-workbench.conf ] && ok "harden: real sshd -t failure -> rolled back" || fail "rollback"
rm /etc/ssh/sshd_config.d/00-broken.conf; bash $S/server/harden.sh --only ssh --yes >/dev/null

# inventory
bash $S/server/inventory.sh --json > /tmp/inv.json; jq -e --arg v "Ubuntu $OS_VER" '.facts["os.name"] | startswith($v)' /tmp/inv.json >/dev/null \
  && jq -e '.facts["sec.ssh_dropin"] == "yes" and .facts["sec.fail2ban"] == "installed"' /tmp/inv.json >/dev/null && ok "inventory --json: real facts, valid JSON" || { cat /tmp/inv.json; fail "inventory"; }
bash $S/server/inventory.sh --out /var/lib/server-infra-workbench/inventory >/dev/null; apt-get install -y -qq htop >/dev/null 2>&1 || true
bash $S/server/inventory.sh --install-cron --yes >/dev/null && [ -f /etc/cron.d/vsw-inventory ] && /usr/local/lib/server-infra-workbench/server/inventory.sh --out /var/lib/server-infra-workbench/inventory >/dev/null \
  && [ -f /var/lib/server-infra-workbench/inventory/inventory.md ] && ok "inventory: cron install, installed copy runs" || fail "inventory cron"

# update: plan only (an upgrade run would take minutes)
bash $S/server/update.sh --dry-run > /tmp/o 2>&1 && grep -qE 'upgradable|up to date' /tmp/o && ok "update --dry-run: real apt plan" || { cat /tmp/o; fail "update plan"; }

# env init / check
PW="it pass \$x#$(openssl rand -hex 3)"  # quoting probe around a generated part, never hardcoded
mkdir -p /srv/app; printf 'DB_HOST=10.0.0.5\nDB_PASSWORD=%s\nDB_USERNAME=app_stg\n' "$PW" > /tmp/db.env
bash $S/env/env.sh init --env stg --path /srv/app/.env --from /tmp/db.env --url https://stg.example.test --yes > /tmp/o 2>&1 || { cat /tmp/o; fail "env init"; }
[ "$(stat -c %a /srv/app/.env)" = 600 ] && grep -qxF "DB_PASSWORD='$PW'" /srv/app/.env && ! grep -q 'it pass' /tmp/o && ok "env init: real openssl APP_KEY, 600, quoted, values not shown" || fail "env init result"
bash $S/env/env.sh check --env stg --path /srv/app/.env >/dev/null && ok "env check: clean" || fail "env check"

# fixkeys as root: real chown, real ssh-keygen, real sshd -T (incl. a custom AuthorizedKeysFile)
useradd -m -s /bin/bash deploy; chmod 775 /home/deploy; ssh-keygen -q -t ed25519 -N '' -C it@deploy -f /tmp/itkey
K=$S/ssh/fixkeys.sh; export FIXKEYS_TTY=/dev/null
bash $K add --user deploy --key-file /tmp/itkey.pub --yes >/dev/null 2>&1 && [ "$(stat -c '%U %a' /home/deploy/.ssh/authorized_keys)" = "deploy 600" ] \
  && [ "$(stat -c '%U %a' /home/deploy/.ssh)" = "deploy 700" ] && ok "fixkeys add: owned by deploy, 700/600" || fail "fixkeys add"
bash $K diagnose --user deploy > /tmp/o 2>&1; grep -q 'FIX   home is 775' /tmp/o && grep -q 'sshd  pubkeyauthentication yes' /tmp/o && ok "fixkeys diagnose: effective sshd -T settings, home perms" || { cat /tmp/o; fail "fixkeys diagnose"; }
bash $K perms --user deploy >/dev/null 2>&1; [ "$(stat -c %a /home/deploy)" = 755 ] && ok "fixkeys perms: home fixed" || fail "fixkeys perms"
printf 'AuthorizedKeysFile /etc/ssh/keys/%%u\n' > /etc/ssh/sshd_config.d/05-keys.conf; mkdir -p /etc/ssh/keys
bash $K add --user deploy --key-file /tmp/itkey.pub --yes > /tmp/o 2>&1; grep -q 'AuthorizedKeysFile /etc/ssh/keys/deploy' /tmp/o && [ -s /etc/ssh/keys/deploy ] && [ "$(stat -c '%U %a' /etc/ssh/keys)" = "root 755" ] \
  && ok "fixkeys: follows sshd -T AuthorizedKeysFile (%u)" || { cat /tmp/o; fail "fixkeys akf"; }
rm /etc/ssh/sshd_config.d/05-keys.conf; unset FIXKEYS_TTY
echo "server-it: $pass passed, 0 failed"
INNER
