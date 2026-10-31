#!/usr/bin/env bash
# =============================================================================
#  update.sh - apt upgrades with a reboot window, safe for DB servers
# =============================================================================
#  Plan first (what is upgradable, whether a reboot is pending), then confirm.
#  Docker packages (docker-ce, containerd.io, ...) restart every container, so
#  on a server with running containers they are held for this run unless you
#  pass --allow-docker. Reboots happen only inside --reboot-window (server
#  time; DigitalOcean droplets default to UTC): inside it the server reboots in
#  1 minute; outside it a reboot is scheduled for the window's start.
#
#  USAGE
#    update.sh                                    plan only
#    update.sh --yes --reboot-window 02:00-04:00  upgrade; reboot in the window if needed
#    update.sh --yes --no-reboot                  upgrade, never reboot (reports if one is due)
#    update.sh --security-only --yes              only security updates (unattended-upgrade)
#    update.sh --host db-1 --yes --reboot-window 03:00-05:00
#
#  OPTIONS
#    --reboot-window HH:MM-HH:MM   may cross midnight (23:00-01:00)
#    --no-reboot                   never reboot     --full   dist-upgrade (new deps, removals)
#    --allow-docker                upgrade Docker too (restarts containers)
#    --backup-first                run /root/docker-db-server-manager.sh backup before upgrading
#    --no-refresh                  skip apt-get update in the plan
#    --dry-run, -n  --yes, -y  --host H  --quiet, -q (no progress lines)  -h, --help
# =============================================================================
set -euo pipefail
TOOL=update
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); print}' "$0"; }

WINDOW="" NOREBOOT=0 FULL=0 SECURITY=0 ALLOW_DOCKER=0 BACKUP_FIRST=0 REFRESH=1 HOST=""
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --reboot-window) WINDOW="${2:?}"; shift 2 ;;
    --no-reboot) NOREBOOT=1; shift ;;
    --full) FULL=1; shift ;;
    --security-only) SECURITY=1; shift ;;
    --allow-docker) ALLOW_DOCKER=1; shift ;;
    --backup-first) BACKUP_FIRST=1; shift ;;
    --no-refresh) REFRESH=0; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --quiet|-q) export VSW_QUIET=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --host) HOST="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
hm='([01][0-9]|2[0-3]):[0-5][0-9]'
[[ -z "$WINDOW" || "$WINDOW" =~ ^$hm-$hm$ ]] || CODE=2 die "--reboot-window takes HH:MM-HH:MM (24h), e.g. 02:00-04:00"
[ -z "$WINDOW" ] || [ "$NOREBOOT" = 0 ] || CODE=2 die "--reboot-window and --no-reboot conflict"
if [ -n "$HOST" ]; then
  rest=(); skip_next=0
  for a in "${ARGS[@]}"; do if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi; [ "$a" = --host ] && { skip_next=1; continue; }; rest+=("$a"); done
  remote "$HOST" "$0" "${rest[@]+"${rest[@]}"}"; exit $?
fi

mins() { local h="${1%%:*}" m="${1##*:}"; echo $((10#$h * 60 + 10#$m)); }
in_window() { # in_window HH:MM-HH:MM NOW(HH:MM)
  local s e n; s="$(mins "${1%-*}")"; e="$(mins "${1#*-}")"; n="$(mins "$2")"
  if [ "$s" -le "$e" ]; then [ "$n" -ge "$s" ] && [ "$n" -lt "$e" ]; else [ "$n" -ge "$s" ] || [ "$n" -lt "$e" ]; fi
}
NOW="${VSW_NOW:-$(date +%H:%M)}"
REBOOT_FLAG="$R/var/run/reboot-required"
DOCKER_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io"

# ---- plan ------------------------------------------------------------------------
have apt-get || die "apt-get not found (Ubuntu/Debian only)"
[ "$REFRESH" = 1 ] && { apt-get update -q >/dev/null 2>&1 || warn "apt-get update failed (using cached lists)"; }
UPG="$(apt list --upgradable 2>/dev/null | sed -n 's#^\([^/]*\)/.*#\1#p' || true)"
n=0; [ -z "$UPG" ] || n="$(printf '%s\n' "$UPG" | grep -c .)"
say "update plan ($(hostname 2>/dev/null), server time $NOW):"
if [ "$n" -eq 0 ]; then ok "no upgradable packages"; else todo "$n upgradable: $(printf '%s\n' "$UPG" | head -15 | tr '\n' ' ')$([ "$n" -gt 15 ] && echo '...')"; fi
held=""
running=0; have docker && running="$(docker ps -q 2>/dev/null | grep -c . || true)"
for p in $DOCKER_PKGS; do printf '%s\n' "$UPG" | grep -x "$p" >/dev/null && held+="$p "; done
if [ -n "$held" ] && [ "$running" -gt 0 ] && [ "$ALLOW_DOCKER" = 0 ]; then
  warn "docker packages upgradable ($held) with $running running container(s): held for this run"
  why "a Docker upgrade restarts every container (DB downtime); do it in a window with --allow-docker"
else held=""; fi
pending_reboot=0; [ -f "$REBOOT_FLAG" ] && pending_reboot=1
[ "$pending_reboot" = 1 ] && warn "reboot already required ($( { tr '\n' ' ' < "$R/var/run/reboot-required.pkgs"; } 2>/dev/null || echo 'see /var/run/reboot-required.pkgs'))"
if [ -n "$WINDOW" ]; then
  if in_window "$WINDOW" "$NOW"; then say "  reboot window $WINDOW: open now - a needed reboot happens in 1 minute"
  else say "  reboot window $WINDOW: closed - a needed reboot is scheduled for ${WINDOW%-*}"; fi
elif [ "$NOREBOOT" = 1 ]; then say "  reboots: never (--no-reboot)"
else say "  reboots: not without --reboot-window (reported only)"; fi
[ "$BACKUP_FIRST" = 1 ] && say "  backup first: /root/docker-db-server-manager.sh backup"

if [ "$n" -eq 0 ] && { [ "$pending_reboot" = 0 ] || [ -z "$WINDOW" ]; }; then summary; exit 0; fi
if [ "$DRY" = 1 ]; then summary; say "plan only - rerun with --yes"; exit 0; fi
[ "$(id -u)" -eq 0 ] || [ -n "$R" ] || die "run as root (sudo)"
lock
confirm "upgrade $n package(s)$([ -n "$WINDOW" ] && echo " and reboot in $WINDOW if needed")"
audit confirmed "packages=$n window=${WINDOW:-none} held=${held:-none}"

# ---- apply -----------------------------------------------------------------------
if [ "$BACKUP_FIRST" = 1 ]; then
  [ -x "$R/root/docker-db-server-manager.sh" ] || die "--backup-first: /root/docker-db-server-manager.sh not found"
  "$R/root/docker-db-server-manager.sh" backup || die "backup failed - not upgrading"
fi
was_held="$(apt-mark showhold 2>/dev/null || true)"
newly=""
for p in $held; do printf '%s\n' "$was_held" | grep -x "$p" >/dev/null || newly+="$p "; done
# shellcheck disable=SC2086  # word lists
unhold() { [ -z "$newly" ] || apt-mark unhold $newly >/dev/null 2>&1 || true; newly=""; }
# shellcheck disable=SC2086  # word lists
[ -z "$newly" ] || { apt-mark hold $newly >/dev/null; trap 'unhold; rm -rf "$LOCK"' EXIT; }
export DEBIAN_FRONTEND=noninteractive
opts=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
if [ "$n" -gt 0 ]; then
  if [ "$SECURITY" = 1 ]; then have unattended-upgrade || apt-get install "${opts[@]}" unattended-upgrades; unattended-upgrade -v
  elif [ "$FULL" = 1 ]; then progress_run "apt-get dist-upgrade ($n packages)" apt-get "${opts[@]}" dist-upgrade
  else progress_run "apt-get upgrade ($n packages)" apt-get "${opts[@]}" upgrade; fi
  apt-get -y -q autoremove >/dev/null 2>&1 || true
  ok "upgrade done"; audit applied "upgrade packages=$n"
fi
unhold
if [ -f "$REBOOT_FLAG" ]; then
  if [ -n "$WINDOW" ]; then
    if in_window "$WINDOW" "$NOW"; then when="+1"; else when="${WINDOW%-*}"; fi
    shutdown -r "$when" "vps-server-workbench: reboot after updates" && ok "reboot scheduled ($when); cancel with: shutdown -c"
    audit applied "reboot scheduled=$when"
  else warn "reboot required - run in a window: update.sh --yes --reboot-window HH:MM-HH:MM"; fi
fi
summary
audit succeeded "packages=$n"
