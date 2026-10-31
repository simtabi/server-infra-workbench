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
# docker group = root-equivalent: report, allow-list, confirmed fix
fresh; printf 'root:x:0:\ndocker:x:999:ploi,deploy\n' > "$T/root/etc/group"
bash "$H" --only dockergroup >"$T/o" 2>&1 || true
grep -q 'warn  dockergroup: ploi deploy in the docker group' "$T/o" && grep -q 'nothing to change' "$T/o" && ok "harden: reports non-root docker group members (warn, no change by default)" || { cat "$T/o"; fail "docker group report"; }
bash "$H" --only dockergroup --docker-allow ploi,deploy >"$T/o" 2>&1; grep -q 'ok    dockergroup: only root and allowed' "$T/o" && ok "harden: DOCKER_GROUP_ALLOW exempts intended users" || { cat "$T/o"; fail "docker allow"; }
DOCKER_GROUP_ALLOW=Bad bash "$H" --only dockergroup >/dev/null 2>&1 && fail "bad allow list" || ok "harden: validates DOCKER_GROUP_ALLOW"
if bash "$H" --only dockergroup --fix-docker-group --check >/dev/null 2>&1; then fail "--check with docker fix pending"; fi
DOCKER_GROUP_ALLOW=deploy bash "$H" --only dockergroup --fix-docker-group --yes >"$T/o" 2>&1
grep -qx 'docker:x:999:deploy' "$T/root/etc/group" && ls "$T/root/etc/group".bak.* >/dev/null 2>&1 && grep -q 'item=dockergroup' "$T/log/audit.log" \
  && ok "harden --fix-docker-group --yes: removes only non-allowed users, backup + audit" || { cat "$T/o" "$T/root/etc/group"; fail "docker fix"; }

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

# --- env init / check ------------------------------------------------------------------------
E=src/shell/env/env.sh
fresh; mkdir -p "$T/root/home/ploi/shop.example.com"; EF="$T/root/home/ploi/shop.example.com/.env"
printf 'DB_CONNECTION=pgsql\nDB_HOST=10.0.0.5\nDB_PORT=6432\nDB_DATABASE=shop_prd\nDB_USERNAME=shop_prd\nDB_PASSWORD=p@ss w$rd#1\n' > "$T/db.env"
bash "$E" init --env prd --site shop.example.com --from "$T/db.env" --url https://shop.example.com --dry-run >"$T/o"
[ ! -f "$EF" ] && grep -q 'generated: APP_KEY (value not shown)' "$T/o" && ok "env init --dry-run: plan, nothing written" || fail "env dry-run"
if bash "$E" init --env prd --site shop.example.com --from "$T/db.env" >"$T/o" 2>&1; then fail "prd without https"; fi
grep -q 'APP_URL must be https' "$T/o" && [ ! -f "$EF" ] && ok "env init: refuses prd without an https APP_URL" || fail "env validate"
: > "$T/tty"; bash "$E" init --env prd --site shop.example.com --from "$T/db.env" --url https://shop.example.com --yes >/dev/null 2>&1 && fail "prd --yes"
echo shop.example.com > "$T/tty"; bash "$E" init --env prd --site shop.example.com --from "$T/db.env" --url https://shop.example.com >"$T/o" 2>&1
[ "$(stat -c %a "$EF" 2>/dev/null || stat -f %Lp "$EF")" = 600 ] && grep -q '^APP_DEBUG=false$' "$EF" && grep -q '^APP_ENV=production$' "$EF" \
  && grep -qE '^APP_KEY=base64:.{44}$' "$EF" && grep -q "^DB_PASSWORD='p@ss w\$rd#1'$" "$EF" && ok "env init prd: typed confirm, 600, defaults, APP_KEY, quoting" || { cat "$T/o"; fail "env init write"; }
! grep -q 'p@ss' "$T/o" && ! grep -q "$(sed -n 's/^APP_KEY=//p' "$EF")" "$T/o" && ok "env init: values never printed" || fail "env leaked"
key="$(grep '^APP_KEY=' "$EF")"
bash "$E" init --env prd --site shop.example.com --set APP_KEY=base64:other --set MAIL_MAILER=smtp >"$T/o" 2>&1
[ "$(grep '^APP_KEY=' "$EF")" = "$key" ] && grep -q 'APP_KEY already set - kept' "$T/o" && grep -q 'changed: MAIL_MAILER' "$T/o" && ls "$EF".bak.* >/dev/null \
  && ok "env init rerun: keeps APP_KEY, key-only diff, backup" || { cat "$T/o"; fail "env rerun"; }
bash "$E" check --env prd --site shop.example.com >/dev/null && ok "env check: clean prd .env passes" || fail "env check clean"
sed -i.x '/^REDIS_PORT=/d; s/^DB_USERNAME=.*/DB_USERNAME=postgres/' "$EF"; echo 'EXTRA_THING=1' >> "$EF"
bash "$E" check --env prd --site shop.example.com >"$T/o" 2>&1 && fail "env check should fail"
grep -q 'missing: REDIS_PORT' "$T/o" && grep -q 'extra (not in the reference): EXTRA_THING' "$T/o" && grep -q 'superuser' "$T/o" \
  && ok "env check: missing, extra and superuser user reported" || { cat "$T/o"; fail "env check findings"; }
bash "$E" init --env prd --site shop.example.com --set 'bad-key=1' >/dev/null 2>&1 && fail "bad key" || ok "env init: rejects bad keys"
# env init --addons: merges /opt/vsw-addons/*/laravel.env (600 only), --set wins, empty never clears, values hidden
sed -i.x 's/^DB_USERNAME=.*/DB_USERNAME=shop_prd/; /^AWS_ACCESS_KEY_ID=/d' "$EF"; echo 'AWS_ACCESS_KEY_ID=keep-mine' >> "$EF"
AD="$T/root/opt/vsw-addons"; mkdir -p "$AD/gotenberg" "$AD/garage" "$AD/seaweedfs"
(umask 077; printf 'GOTENBERG_URL=http://127.0.0.1:3000\nGOTENBERG_PASSWORD=GotSecret42\n' > "$AD/gotenberg/laravel.env"
 printf '# garage\nFILESYSTEM_DISK=s3\nAWS_ACCESS_KEY_ID=\nAWS_SECRET_ACCESS_KEY=GarSecret99\nAWS_BUCKET=app\n' > "$AD/garage/laravel.env")
printf 'AWS_REGION=leaky\n' > "$AD/seaweedfs/laravel.env"; chmod 644 "$AD/seaweedfs/laravel.env"
echo shop.example.com > "$T/tty"; bash "$E" init --env prd --site shop.example.com --addons --set AWS_BUCKET=override >"$T/o" 2>&1 || true
grep -q '^GOTENBERG_PASSWORD=GotSecret42$' "$EF" && grep -q '^AWS_SECRET_ACCESS_KEY=GarSecret99$' "$EF" && grep -q '^AWS_ACCESS_KEY_ID=keep-mine$' "$EF" \
  && grep -q '^AWS_BUCKET=override$' "$EF" && ! grep -q 'leaky' "$EF" && grep -q 'add-ons: garage gotenberg' "$T/o" && grep -q 'seaweedfs/laravel.env is mode 644' "$T/o" \
  && [ "$(stat -c %a "$EF" 2>/dev/null || stat -f %Lp "$EF")" = 600 ] && ok "env init --addons: merged (600 files only), --set wins, empty keeps yours, 600" || { cat "$T/o"; fail "env addons"; }
! grep -qE 'GotSecret42|GarSecret99' "$T/o" && ok "env init --addons: add-on values never printed" || fail "env addons leaked"

# --- server init ------------------------------------------------------------------------------
I=src/shell/server/init.sh
stub timedatectl 'case "$1" in show) echo Etc/UTC;; esac'
stub swapon 'case "$1" in --show) ;; esac'
stub fallocate 'touch "$3"'
stub mkswap
stub curl 'while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo FAKE-GPG > "$2"; }; shift; done'
initroot() { fresh; mkdir -p "$T/root/proc" "$T/root/etc"; printf 'MemTotal:       2014000 kB\nSwapTotal: 0 kB\n' > "$T/root/proc/meminfo"
  printf 'PRETTY_NAME="Ubuntu 24.04.3 LTS"\nVERSION_CODENAME=noble\n' > "$T/root/etc/os-release"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly t' > "$T/root/root/.ssh/authorized_keys"
  echo 'Include /etc/ssh/sshd_config.d/*.conf' > "$T/root/etc/ssh/sshd_config"; }
initroot
bash "$I" >/dev/null 2>&1 && fail "init without role" || ok "init: --role is required"
stub docker 'case "$1" in compose) exit 1;; ps) ;; esac'
bash "$I" --role db --dry-run >"$T/o"
grep -q 'todo  timezone: Etc/UTC -> UTC' "$T/o" && grep -q 'todo  swap: create /swapfile 2G (RAM 1966 MB)' "$T/o" && grep -q "todo  docker: add Docker's apt repo (noble)" "$T/o" \
  && grep -q 'todo  harden:' "$T/o" && [ ! -e "$T/root/swapfile" ] && ! grep -q 'apt-get' "$T/calls" && ok "init --dry-run (db): timezone, swap, docker, harden planned; nothing done" || { cat "$T/o"; fail "init plan"; }
bash "$I" --role db >/dev/null 2>&1 && fail "init without yes" || ok "init: not confirmed without --yes"
bash "$I" --role db --yes >"$T/o" 2>&1 || { cat "$T/o"; fail "init apply"; }
grep -q 'timedatectl set-timezone UTC' "$T/calls" && [ -f "$T/root/swapfile" ] && grep -q '^/swapfile none swap' "$T/root/etc/fstab" && grep -q 'vm.swappiness = 10' "$T/root/etc/sysctl.d/91-workbench-swap.conf" \
  && grep -q 'docker-compose-plugin' "$T/calls" && grep -q 'signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable' "$T/root/etc/apt/sources.list.d/docker.list" \
  && grep -q '"live-restore": true' "$T/root/etc/docker/daemon.json" && [ -f "$T/root/etc/ssh/sshd_config.d/10-workbench.conf" ] && grep -q 'tool=init.*outcome=succeeded' "$T/log/audit.log" \
  && ok "init --yes (db): tz, swap+fstab+swappiness, Docker repo+compose, daemon.json, harden, audit" || { cat "$T/o"; fail "init results"; }
stub docker 'case "$1" in ps) ;; esac'; stub timedatectl 'case "$1" in show) echo UTC;; esac'; stub swapon 'case "$1" in --show) echo "/swapfile file 2G";; esac'
stub dpkg-query 'echo "install ok installed"'
bash "$I" --role db --yes >"$T/o" 2>&1; grep -q 'nothing to change' "$T/o" && ok "init: rerun is a no-op" || { cat "$T/o"; fail "init idempotent"; }
stub dpkg-query; stub timedatectl 'case "$1" in show) echo Etc/UTC;; esac'
initroot; mkdir -p "$T/root/home/ploi"
bash "$I" --role web --firewall --dry-run >"$T/o"
grep -q 'docker: not for role web' "$T/o" && ! grep -q 'firewall' "$T/o" && ok "init (web, Ploi): no Docker, firewall left to Ploi" || { cat "$T/o"; fail "init ploi"; }
bash "$I" --role db --dry-run >"$T/o"; grep -q 'looks like a Ploi server' "$T/o" && ok "init: refuses Docker DB stack on a Ploi server" || fail "init ploi db"
bash "$I" --role db --swap 3X >/dev/null 2>&1 && fail "bad swap" || ok "init: validates --swap"

# --- server inventory -------------------------------------------------------------------------
V=src/shell/server/inventory.sh
initroot; mkdir -p "$T/root/home/ploi/shop.example.com"; touch "$T/root/home/ploi/shop.example.com/artisan"
printf 'APP_KEY=base64:secretvalue\nDB_PASSWORD=not-a-real-password\n' > "$T/root/home/ploi/shop.example.com/.env"
stub docker 'case "$1" in ps) echo "pg|postgres:18|Up 3 days (healthy)";; --version) echo "Docker version 28.5.1, build x";; compose) echo "Docker Compose version v2.40.0";; esac'
stub ss "printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 200 10.0.0.5:5432 0.0.0.0:*\n'"
bash "$V" --json >"$T/o"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); f=d["facts"]; assert f["os.name"]=="Ubuntu 24.04.3 LTS" and f["size.mem_mb"]=="1966" and f["containers.pg"].startswith("postgres:18") and f["sites.shop.example.com"]=="laravel" and f["ver.docker"]=="28.5.1"' "$T/o" \
  && ok "inventory --json: valid JSON with OS, size, containers, sites, versions" || { cat "$T/o"; fail "inventory json"; }
! grep -qE 'secretvalue|not-a-real-password' "$T/o" && ok "inventory: never reads .env values" || fail "inventory leaked"
bash "$V" --out /var/lib/vsw/inv >/dev/null; [ -f "$T/root/var/lib/vsw/inv/inventory.md" ] && grep -q '| mem_mb | 1966 |' "$T/root/var/lib/vsw/inv/inventory.md" && ok "inventory --out: txt/json/md written" || fail "inventory out"
stub ss "printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 200 10.0.0.5:5432 0.0.0.0:*\nLISTEN 0 511 0.0.0.0:6379 0.0.0.0:*\n'"
bash "$V" --out /var/lib/vsw/inv >"$T/o"; grep -q 'changes since the last inventory' "$T/o" && grep -q '^+net.listen.0.0.0.0:6379' "$T/root/var/lib/vsw/inv"/changes-*.diff \
  && grep -q 'tool=inventory.*outcome=changed' "$T/log/audit.log" && ok "inventory: diff vs the last run, audited" || fail "inventory diff"
bash "$V" --install-cron --dry-run >/dev/null; [ ! -e "$T/root/etc/cron.d/vsw-inventory" ] && bash "$V" --install-cron --yes >/dev/null \
  && grep -q 'inventory.sh --out /var/lib/vps-server-workbench/inventory' "$T/root/etc/cron.d/vsw-inventory" && [ -x "$T/root/usr/local/lib/vps-server-workbench/server/inventory.sh" ] \
  && ok "inventory --install-cron: plan, then tool copy + /etc/cron.d" || fail "inventory cron"
cat > "$T/bin/ssh" <<STUB
#!/bin/sh
case "\$*" in *mktemp*) echo "$T/remote";; *"mkdir -p"*) mkdir -p "$T/remote/tool" "$T/remote/lib";; *) VSW_SYSROOT="$T/root" bash "$T/remote/tool/inventory.sh" --txt;; esac
STUB
printf '#!/bin/sh\n[ "$1" = -q ] && shift\nfor a; do last="$a"; done; cp "$1" "%s/remote/${last#*:%s/remote/}"\n' "$T" "$T" > "$T/bin/scp"; chmod +x "$T/bin/ssh" "$T/bin/scp"
export VSW_REPO_ROOT="$T/repo"; mkdir -p "$VSW_REPO_ROOT"; L="$VSW_REPO_ROOT/local/smoketest-client"
bash "$V" --host db-1 --pull --client smoketest-client >"$T/o" 2>&1 && grep -q 'first inventory' "$T/o" && [ -f "$L/inventory/db-1/inventory.json" ] && [ ! -e local/smoketest-client ] \
  && bash "$V" --host db-1 --pull --client smoketest-client >"$T/o" 2>&1 && grep -q 'no changes' "$T/o" \
  && ok "inventory --pull: saved to local/<client>/inventory/<host>/, diff on the next pull" || { cat "$T/o"; fail "inventory pull"; }
rm -f "$T/bin/ssh" "$T/bin/scp"; unset VSW_REPO_ROOT

# --- ssh fixkeys (self-contained; --root = a mounted disk) ------------------------------------
K=src/shell/ssh/fixkeys.sh FR="$T/fk"
fakekey() { python3 -c 'import base64,struct,sys; r=bytes([int(sys.argv[1])])*32; b=struct.pack(">I",11)+b"ssh-ed25519"+struct.pack(">I",32)+r; print("ssh-ed25519 "+base64.b64encode(b).decode()+" "+sys.argv[2])' "$1" "$2"; }
k1="$(fakekey 1 alice@laptop)" k2="$(fakekey 2 bob@desk)"
mkdir -p "$FR/etc" "$FR/home/deploy"; echo 'deploy:x:1000:1000::/home/deploy:/bin/bash' > "$FR/etc/passwd"; chmod 775 "$FR/home/deploy"
export FIXKEYS_TTY="$T/fktty"; : > "$FIXKEYS_TTY"
FK() { bash "$K" --root "$FR" --user deploy "$@"; }
AKF="$FR/home/deploy/.ssh/authorized_keys"
FK add 'ssh-ed25519 AAAAnotakey x' >/dev/null 2>&1 && fail "invalid key accepted"; [ ! -f "$AKF" ] && ok "fixkeys: ssh-keygen rejects an invalid key" || fail "fixkeys invalid"
FK add '-----BEGIN OPENSSH ''PRIVATE KEY-----' >"$T/o" 2>&1 || true; grep -q 'PRIVATE key' "$T/o" && ok "fixkeys: refuses a pasted private key" || fail "fixkeys private"
FK add "$k1" >/dev/null 2>&1 || true; [ ! -f "$AKF" ] && ok "fixkeys add: not confirmed -> nothing written" || fail "fixkeys confirm"
FK add "$k1" --yes >/dev/null 2>&1 && FK add "$k2" --yes >/dev/null 2>&1
[ "$(grep -c ssh-ed25519 "$AKF")" = 2 ] && [ "$(stat -c %a "$AKF" 2>/dev/null || stat -f %Lp "$AKF")" = 600 ] && [ "$(stat -c %a "$FR/home/deploy/.ssh" 2>/dev/null || stat -f %Lp "$FR/home/deploy/.ssh")" = 700 ] \
  && ok "fixkeys add --yes: two keys, .ssh 700, file 600" || fail "fixkeys add"
FK add "from=\"10.0.0.0/8\" $k1" --yes >"$T/o" 2>&1; grep -q 'already present' "$T/o" && ok "fixkeys: exact key match ignores options (no duplicate)" || fail "fixkeys dup"
FK list >"$T/o" 2>&1; grep -q '2. bob@desk  ssh-ed25519  SHA256:' "$T/o" && ok "fixkeys list: labels, types, fingerprints" || fail "fixkeys list"
FK diagnose >"$T/o" 2>&1; grep -q 'FIX   home is 775' "$T/o" && ok "fixkeys diagnose: group-writable home flagged" || fail "fixkeys diagnose"
FK perms >/dev/null 2>&1; [ "$(stat -c %a "$FR/home/deploy" 2>/dev/null || stat -f %Lp "$FR/home/deploy")" = 755 ] && ok "fixkeys perms: home go-w" || fail "fixkeys perms"
FK list >"$T/o" 2>&1; fp2="$(sed -n 's/.*bob@desk  ssh-ed25519  //p' "$T/o")"
FK remove "$fp2" --yes >/dev/null 2>&1; ! grep -q bob@desk "$AKF" && grep -q alice@laptop "$AKF" && ok "fixkeys remove by fingerprint (backup kept)" || fail "fixkeys remove"
FK remove 1 --yes >/dev/null 2>&1 || true; grep -q alice@laptop "$AKF" && ok "fixkeys: last key needs typed EMPTY (--yes is not enough)" || fail "fixkeys last key"
ls "$AKF".bak.* >/dev/null 2>&1 && grep -q 'tool=fixkeys .*outcome=removed .*fp=SHA256:' "$FR/var/log/vps-server-workbench/audit.log" && ! grep -q AAAA "$FR/var/log/vps-server-workbench/audit.log" \
  && ok "fixkeys: backups + audit with fingerprints only" || fail "fixkeys audit"
echo 1 > "$FIXKEYS_TTY"; b1="$(grep -l bob@desk "$AKF".bak.* | head -1)"; FK restore "$(basename "$b1")" --yes >/dev/null 2>&1; [ "$(grep -c ssh-ed25519 "$AKF")" = 2 ] && ok "fixkeys restore: a backup put back" || fail "fixkeys restore"
FK restore /etc/passwd --yes >/dev/null 2>&1 && fail "restore of an arbitrary file" || ok "fixkeys restore: only <file>.bak.* accepted"
printf '2\n%s\ny\nq\n' "$(fakekey 3 carol@ipad)" > "$FIXKEYS_TTY"; FK >/dev/null 2>&1 || true; grep -q carol@ipad "$AKF" && ok "fixkeys menu: prompts read from FIXKEYS_TTY, not stdin" || fail "fixkeys menu"
unset FIXKEYS_TTY

printf '\nsmoke-server: %d passed, 0 failed\n' "$pass"
