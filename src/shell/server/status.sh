#!/usr/bin/env bash
# =============================================================================
#  status.sh - one-screen health of a node: load, RAM, disk, containers, backups
# =============================================================================
#  Read-only. Never reads .env values, keys or passwords: only counts, ages and
#  states. WHY: "is anything wrong right now?" should take one command, not ten,
#  and must be safe to run on prd at any time (no locks, no writes).
#
#  USAGE
#    status.sh                         this node, human readable
#    status.sh --json                  this node, JSON (for scripts and dashboards)
#    status.sh --host db-1             over ssh (sudo -n; tool copied to a temp dir, removed after)
#    status.sh --url https://app.example.com/up [--url ...]   also check health URLs (from here)
#
#  EXIT  0 all fine, 1 something needs a look (listed as "attention")
#
#  OPTIONS
#    --json  --host H  --url URL  -h, --help
#    STATUS_DISK_WARN (default 85 %)  STATUS_BACKUP_MAX_H (default 26)
# =============================================================================
set -euo pipefail
TOOL=status
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

JSON=0 HOST="" URLS=()
DISK_WARN="${STATUS_DISK_WARN:-85}" BACKUP_MAX_H="${STATUS_BACKUP_MAX_H:-26}"
DB_STATE="${STATE_DIR:-$R/var/lib/vps-server-workbench/db}" MON_DIR="${MONITOR_DIR:-$R/opt/vsw-monitor}" ADD_DIR="${ADDON_DIR:-$R/opt/vsw-addons}"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --host) HOST="${2:?}"; shift 2 ;;
    --url) [[ "${2:-}" =~ ^https?://[A-Za-z0-9._:-]+(/[^[:space:]]*)?$ ]] || CODE=2 die "--url needs an http(s) URL"; URLS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
[[ "$DISK_WARN" =~ ^[0-9]+$ && "$BACKUP_MAX_H" =~ ^[0-9]+$ ]] || CODE=2 die "STATUS_DISK_WARN and STATUS_BACKUP_MAX_H must be numbers"

if [ -n "$HOST" ]; then
  ra=(); [ "$JSON" = 1 ] && ra+=(--json)
  REMOTE_NOTTY=1 remote "$HOST" "$HERE/status.sh" "${ra[@]+"${ra[@]}"}" || rc=$?
  for u in "${URLS[@]+"${URLS[@]}"}"; do "$0" --url "$u" >/dev/null 2>&1 || rc=1; done
  exit "${rc:-0}"
fi

ATTN=() FACTS=()
fact() { FACTS+=("$1=$2"); }
attn() { ATTN+=("$1"); }
age_h() { local t; t="$(awk '{print $1; exit}' "$1" 2>/dev/null || true)"; [ -z "$t" ] || echo $(( ($(date +%s) - t) / 3600 )); }  # never fails: a missing stamp is "never"

fact host "$(hostname 2>/dev/null || echo '?')"
fact uptime_days "$(awk '{printf "%d", $1/86400}' "$R/proc/uptime" 2>/dev/null || echo '?')"
{ read -r l1 l5 _ < "$R/proc/loadavg"; } 2>/dev/null || { l1='?' l5='?'; }
cpus="$(nproc 2>/dev/null || echo 1)"; fact load "$l1 $l5 (cpus $cpus)"
awk -v c="$cpus" -v l="$l5" 'BEGIN{exit !(l+0 > c*2)}' 2>/dev/null && attn "load $l5 is above 2x the CPU count"
if [ -r "$R/proc/meminfo" ]; then
  mt="$(awk '/^MemTotal:/{print int($2/1024)}' "$R/proc/meminfo")"; ma="$(awk '/^MemAvailable:/{print int($2/1024)}' "$R/proc/meminfo")"
  fact ram_mb "$((mt - ma)) used of $mt ($ma available)"; [ "$ma" -lt $((mt / 10)) ] && attn "RAM: only $ma MB available"
fi
du_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"; fact disk_root_pct "${du_pct:-?}"
[ -n "$du_pct" ] && [ "$du_pct" -ge "$DISK_WARN" ] && attn "disk / is ${du_pct}% full"
if [ -f "$R/var/run/reboot-required" ]; then fact reboot_required yes; attn "reboot required (kernel/libc update)"; else fact reboot_required no; fi
if have docker && docker info >/dev/null 2>&1; then
  run_n="$(docker ps -q | wc -l | tr -d ' ')"; all_n="$(docker ps -aq | wc -l | tr -d ' ')"; fact containers "$run_n running of $all_n"
  unh="$(docker ps --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ' | sed 's/ $//')"
  [ -z "$unh" ] || attn "unhealthy containers: $unh"
  # only stacks this repo runs: the DB manager (compose project "db") and vsw-* (monitor, add-ons)
  ex="$(docker ps -a --filter status=exited --filter status=restarting --format '{{.Label "com.docker.compose.project"}} {{.Names}}' \
    | awk '$1 == "db" || $2 ~ /^vsw-/ {print $2}' | tr '\n' ' ' | sed 's/ $//' || true)"
  [ -z "$ex" ] || attn "stopped/restarting workbench containers: $ex"
else fact containers "no docker (or no access)"; fi
if [ -d "$DB_STATE" ]; then
  b="$(age_h "$DB_STATE/backup")"; fact db_backup_age_h "${b:-never}"
  { [ -z "$b" ] || [ "$b" -gt "$BACKUP_MAX_H" ]; } && attn "database backup is ${b:-never} hours old (max $BACKUP_MAX_H)"
  o="$(age_h "$DB_STATE/offsite")"; [ -z "$o" ] || fact db_offsite_age_h "$o"
  r="$(age_h "$DB_STATE/restore-test")"; [ -z "$r" ] || fact db_restore_test_age_h "$r"
  d="$(awk '{print $2, $3; exit}' "$DB_STATE/doctor" 2>/dev/null || true)"; [ -z "$d" ] || { fact db_doctor "$d"; case "$d" in fail*) attn "last DB doctor: $d problems" ;; esac; }
fi
units_in() { local x o=""; for x in "$1"/*/stack.env; do [ -f "$x" ] && o="$o $(basename "$(dirname "$x")")"; done; o="${o# }"; echo "${o:-none}"; }
fact monitor "$(units_in "$MON_DIR")"
fact addons "$(units_in "$ADD_DIR")"
for u in "${URLS[@]+"${URLS[@]}"}"; do
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code} %{time_total}' "$u" 2>/dev/null || echo '000 0')"
  fact "url $u" "$code"; case "$code" in 2*|3*) ;; *) attn "health URL $u returned ${code%% *}" ;; esac
done

if [ "$JSON" = 1 ]; then
  esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
  printf '{'; sep=""
  for f in "${FACTS[@]}"; do printf '%s%s: %s' "$sep" "$(esc "${f%%=*}")" "$(esc "${f#*=}")"; sep=", "; done
  printf '%s"attention": [' "$sep"; sep=""; for x in "${ATTN[@]+"${ATTN[@]}"}"; do printf '%s%s' "$sep" "$(esc "$x")"; sep=", "; done; printf '], "ok": %s}\n' "$([ ${#ATTN[@]} = 0 ] && echo true || echo false)"
else
  for f in "${FACTS[@]}"; do printf '  %-22s %s\n' "${f%%=*}" "${f#*=}"; done
  if [ ${#ATTN[@]} = 0 ]; then echo "status: all fine"; else echo "attention:"; for x in "${ATTN[@]}"; do echo "  - $x"; done; fi
fi
[ ${#ATTN[@]} = 0 ]
