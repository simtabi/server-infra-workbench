#!/usr/bin/env bash
# =============================================================================
#  init.sh - first-boot setup for a fresh Ubuntu LTS droplet, 24.04 or 26.04 (db, web or base)
# =============================================================================
#  One command after the droplet exists and your key works. Prints a plan,
#  changes nothing until confirmed, locks, logs to the audit log, re-runnable.
#
#  ITEMS (pick with --only / --skip)
#    timezone   set the clock zone (default UTC: logs and cron agree everywhere)
#    swap       /swapfile (default 2G) when the droplet has no swap; db role
#               also sets vm.swappiness=10 so the DB cache is not swapped early
#    packages   base tools: ca-certificates curl gnupg jq unzip htop
#    docker     db role only: Docker Engine + compose plugin from Docker's apt
#               repo, /etc/docker/daemon.json with log rotation + live-restore
#    harden     runs server/harden.sh --role <role> (ssh keys only, fail2ban,
#               unattended security upgrades, sysctl, journald)
#
#  Ploi servers (web role): Ploi provisions PHP, nginx, the firewall and its own
#  packages, so init only does timezone, swap, base packages and harden there, never ufw.
#
#  USAGE
#    init.sh --role db                     plan only
#    init.sh --role db --yes               apply
#    init.sh --host db-1 --role db --yes   over ssh (copies itself + harden.sh)
#
#  OPTIONS
#    --role db|web|base  (required)   --timezone Area/City (default UTC)
#    --swap 2G|4096M|0   (0 = never create swap)
#    --only a,b  --skip a,b   --firewall (passed to harden; not on Ploi)
#    --dry-run, -n  --yes, -y  --host H  --quiet, -q (no progress lines)  -h, --help
# =============================================================================
set -euo pipefail
TOOL=init
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

ROLE="" TZ_WANT=UTC SWAP=2G ONLY="" SKIP="" FIREWALL=0 HOST=""
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:?}"; shift 2 ;;
    --timezone) TZ_WANT="${2:?}"; shift 2 ;;
    --swap) SWAP="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --skip) SKIP="${2:?}"; shift 2 ;;
    --firewall) FIREWALL=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --quiet|-q) export SIWO_QUIET=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --host) HOST="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
case "$ROLE" in db|web|base) ;; "") CODE=2 die "--role db|web|base is required" ;; *) CODE=2 die "--role must be db, web or base" ;; esac
[[ "$TZ_WANT" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || CODE=2 die "--timezone looks like Area/City (e.g. Europe/London) or UTC"
[[ "$SWAP" =~ ^(0|[1-9][0-9]*[MG])$ ]] || CODE=2 die "--swap takes 0, e.g. 2G or 4096M"
if [ -n "$HOST" ]; then
  rest=(); skip_next=0
  for a in "${ARGS[@]}"; do if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi; [ "$a" = --host ] && { skip_next=1; continue; }; rest+=("$a"); done
  REMOTE_EXTRA=("$HERE/harden.sh"); remote "$HOST" "$0" "${rest[@]+"${rest[@]}"}"; exit $?
fi

PLOI=0; ploi_managed && PLOI=1
ITEMS="timezone swap packages docker harden"
want() { local i="$1"
  [ -n "$ONLY" ] && { [[ ",$ONLY," == *",$i,"* ]] || return 1; }
  [[ ",$SKIP," == *",$i,"* ]] && return 1; return 0; }
pkg_ok() { have dpkg-query && dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep 'install ok installed' >/dev/null; }
BASE_PKGS="ca-certificates curl gnupg jq unzip htop"
F_SWAP="$R/swapfile" F_FSTAB="$R/etc/fstab" F_SWAPPY="$R/etc/sysctl.d/91-workbench-swap.conf"
F_DAEMON="$R/etc/docker/daemon.json" F_DKEY="$R/etc/apt/keyrings/docker.asc" F_DLIST="$R/etc/apt/sources.list.d/docker.list"
daemon_json() { printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" },\n  "live-restore": true\n}\n'; }
swap_active() { [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; }
cur_tz() { timedatectl show -p Timezone --value 2>/dev/null || cat "$R/etc/timezone" 2>/dev/null || echo unknown; }
[ -z "$R" ] && ! have timedatectl && [ ! -f /usr/share/zoneinfo/UTC ] && [ "$TZ_WANT" != UTC ] && warn "no timedatectl and no tzdata: install tzdata first"
mem_mb() { awk '/^MemTotal:/ {print int($2/1024)}' "$R/proc/meminfo" 2>/dev/null || echo 0; }
codename() { local c; c="$(sed -n 's/^VERSION_CODENAME=//p' "$R/etc/os-release" 2>/dev/null | tr -d '"')"; echo "${c:-noble}"; }

PENDING=()
plan_item() {
  case "$1" in
    timezone)
      if [ "$(cur_tz)" = "$TZ_WANT" ]; then ok "timezone: $TZ_WANT"
      else todo "timezone: $(cur_tz) -> $TZ_WANT"; PENDING+=(timezone); why "one zone on every server keeps logs, cron and backups comparable"; fi ;;
    swap)
      if [ "$SWAP" = 0 ]; then ok "swap: not managed (--swap 0)"
      elif swap_active || [ -f "$F_SWAP" ]; then ok "swap: present"
      else todo "swap: create /swapfile $SWAP (RAM $(mem_mb) MB), add to /etc/fstab"; PENDING+=(swap)
        why "a small droplet without swap gets OOM-killed (often the DB) on a memory spike"; fi
      if [ "$ROLE" = db ] && [ "$SWAP" != 0 ]; then
        if [ -f "$F_SWAPPY" ]; then ok "swap: vm.swappiness=10 for the DB"
        else todo "swap: vm.swappiness=10 ($F_SWAPPY)"; [[ " ${PENDING[*]} " == *" swap "* ]] || PENDING+=(swap); fi
      fi ;;
    packages)
      local miss="" p; for p in $BASE_PKGS; do pkg_ok "$p" || miss="$miss $p"; done
      if [ -z "$miss" ]; then ok "packages: base tools installed"
      else todo "packages: apt-get install$miss"; PENDING+=(packages); fi ;;
    docker)
      [ "$ROLE" = db ] || { ok "docker: not for role $ROLE"; return 0; }
      if [ "$PLOI" = 1 ]; then warn "docker: this looks like a Ploi server; the DB stack belongs on its own droplet - skipped"; return 0; fi
      if have docker && docker compose version >/dev/null 2>&1; then ok "docker: engine + compose plugin"
      else todo "docker: add Docker's apt repo ($(codename)), install docker-ce, compose plugin"; PENDING+=(docker)
        why "the DB manager runs Postgres/MySQL/Redis as compose services"; fi
      if [ -f "$F_DAEMON" ] && ! cmp -s "$F_DAEMON" <(daemon_json); then warn "docker: $F_DAEMON exists and differs - left alone (want log rotation + live-restore)"
      elif [ ! -f "$F_DAEMON" ]; then todo "docker: write $F_DAEMON (10m x 3 log rotation, live-restore)"; [[ " ${PENDING[*]} " == *" docker "* ]] || PENDING+=(docker)
        why "unrotated container logs fill the disk; live-restore keeps containers up across a dockerd restart"
      else ok "docker: daemon.json log rotation + live-restore"; fi ;;
    harden)
      [ -f "$HERE/harden.sh" ] || { bad "harden: $HERE/harden.sh not found"; return 0; }
      local hargs=(--role "$ROLE" --dry-run); [ "$FIREWALL" = 1 ] && [ "$PLOI" = 0 ] && hargs+=(--firewall)
      local out; out="$(bash "$HERE/harden.sh" "${hargs[@]}" 2>&1 || true)"
      if grep -q 'nothing to change' <<<"$out"; then ok "harden: baseline in place"
      else todo "harden: $(grep -c '^  todo' <<<"$out" || true) change(s) (see: siwo server harden --role $ROLE)"; PENDING+=(harden)
        grep -E '^  (todo|FAIL)' <<<"$out" | sed 's/^/    /' || true; fi ;;
  esac
}

apply_item() {
  case "$1" in
    timezone)
      if have timedatectl && timedatectl set-timezone "$TZ_WANT" 2>/dev/null; then :
      else # no systemd (containers, minimal images): the Debian way
        [ -f "$R/usr/share/zoneinfo/$TZ_WANT" ] || die "unknown timezone $TZ_WANT (install tzdata?)"
        ln -sf "/usr/share/zoneinfo/$TZ_WANT" "$R/etc/localtime"; echo "$TZ_WANT" | write_file "$R/etc/timezone" 644
      fi ;;
    swap)
      if ! swap_active && [ ! -f "$F_SWAP" ]; then
        (umask 077; fallocate -l "$SWAP" "$F_SWAP") || die "fallocate $SWAP failed"
        chmod 600 "$F_SWAP"; mkswap "$F_SWAP" >/dev/null; swapon "$F_SWAP"
        grep -qE '^/swapfile[[:space:]]' "$F_FSTAB" 2>/dev/null || { backup "$F_FSTAB" >/dev/null; echo '/swapfile none swap sw 0 0' >> "$F_FSTAB"; }
      fi
      if [ "$ROLE" = db ]; then printf '# Managed by server-infra-workbench init.sh\nvm.swappiness = 10\n' | write_file "$F_SWAPPY" 644
        sysctl -p "$F_SWAPPY" >/dev/null 2>&1 || true; fi ;;
    packages)
      export DEBIAN_FRONTEND=noninteractive
      progress_run "apt-get update" mute apt-get update -q
      # shellcheck disable=SC2086  # word list
      progress_run "apt-get install base packages" mute apt-get install -y -q --no-install-recommends $BASE_PKGS ;;
    docker)
      if ! { have docker && docker compose version >/dev/null 2>&1; }; then
        mkdir -p "$(dirname "$F_DKEY")"; install -d -m 755 "$(dirname "$F_DKEY")"
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$F_DKEY" || die "could not fetch Docker's apt key"
        chmod a+r "$F_DKEY"
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
          "$(dpkg --print-architecture 2>/dev/null || echo amd64)" "$(codename)" | write_file "$F_DLIST" 644
        export DEBIAN_FRONTEND=noninteractive
        progress_run "apt-get update (Docker repo)" mute apt-get update -q
        progress_run "install Docker Engine + compose" mute apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      fi
      if [ ! -f "$F_DAEMON" ]; then daemon_json | write_file "$F_DAEMON" 644; systemctl restart docker 2>/dev/null || true; fi
      systemctl enable --now docker >/dev/null 2>&1 || true ;;
    harden)
      local hargs=(--role "$ROLE" --yes); [ "$FIREWALL" = 1 ] && [ "$PLOI" = 0 ] && hargs+=(--firewall)
      bash "$HERE/harden.sh" "${hargs[@]}" | sed 's/^/    /' || die "harden failed (see above); init stopped" ;;
  esac
  ok "$1: applied"; audit applied "item=$1 role=$ROLE"
}

say "init plan (role $ROLE$( [ "$PLOI" = 1 ] && echo ', Ploi server'), $(mem_mb) MB RAM):"
for i in $ITEMS; do want "$i" && plan_item "$i"; done
[ "$ROLE" = web ] && [ "$PLOI" = 0 ] && warn "web role without Ploi: provision the server in Ploi first (it installs PHP, nginx and the firewall)"
if [ "${#PENDING[@]}" -eq 0 ]; then summary; say "nothing to change"; exit $(( c_fail > 0 ? 1 : 0 )); fi
if [ "$DRY" = 1 ]; then summary; say "plan only - rerun with --yes to apply"; exit 0; fi
[ "$(id -u)" -eq 0 ] || [ -n "$R" ] || die "run as root (sudo)"
lock
confirm "apply ${#PENDING[@]} init step(s) on a $ROLE server: ${PENDING[*]}"
audit confirmed "items=${PENDING[*]} role=$ROLE"
for i in "${PENDING[@]}"; do apply_item "$i"; done
summary
audit succeeded "items=${PENDING[*]} role=$ROLE"
say "next: siwo server inventory   (record what this server is now)"
