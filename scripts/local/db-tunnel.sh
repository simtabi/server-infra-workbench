#!/usr/bin/env bash
# db-tunnel.sh - open an SSH tunnel from your workstation to a DB server whose
# ports listen only on the private VPC IP (and Adminer only on 127.0.0.1).
#
# Usage: db-tunnel.sh [options] <engine>...
#   engines: postgres pgbouncer mysql mariadb adminer all
# Options:
#   --host HOST      SSH destination: user@public-ip or an ~/.ssh/config alias (or DB_TUNNEL_HOST)
#   --private-ip IP  DB server private VPC IP the ports bind to (or DB_PRIVATE_IP)
#   --background     fork into the background (ssh -f); stop with: pkill -f 'ssh -N .*<host>'
#   --print          print the ssh command, don't run it
#   -h|--help
# Local ports (override with env): LOCAL_PG=15432 LOCAL_PGBOUNCER=16432
#   LOCAL_MYSQL=13306 LOCAL_MARIADB=13307 LOCAL_ADMINER=8081
# Remote ports match the manager defaults (PG_PORT=5432 PGBOUNCER_PORT=6432
#   MYSQL_PORT=3306 MARIADB_PORT=3307 ADMINER_PORT=8081); override with the same names.
#
# Example:
#   scripts/local/db-tunnel.sh --host ploi@203.0.113.10 --private-ip 10.0.0.5 postgres adminer
set -euo pipefail

HOST="${DB_TUNNEL_HOST:-}"; PIP="${DB_PRIVATE_IP:-}"; BG=0; PRINT=0; ENG=()
PG_PORT="${PG_PORT:-5432}"; PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
MYSQL_PORT="${MYSQL_PORT:-3306}"; MARIADB_PORT="${MARIADB_PORT:-3307}"; ADMINER_PORT="${ADMINER_PORT:-8081}"
LOCAL_PG="${LOCAL_PG:-15432}"; LOCAL_PGBOUNCER="${LOCAL_PGBOUNCER:-16432}"
LOCAL_MYSQL="${LOCAL_MYSQL:-13306}"; LOCAL_MARIADB="${LOCAL_MARIADB:-13307}"; LOCAL_ADMINER="${LOCAL_ADMINER:-8081}"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --private-ip) PIP="${2:-}"; shift 2 ;;
    --background) BG=1; shift ;;
    --print) PRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    all) ENG+=(postgres pgbouncer mysql mariadb adminer); shift ;;
    postgres|pgbouncer|mysql|mariadb|adminer) ENG+=("$1"); shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$HOST" ] || die "--host is required (user@public-ip or ssh alias)"
[ ${#ENG[@]} -gt 0 ] || die "name at least one engine: postgres pgbouncer mysql mariadb adminer all"

args=(-N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30)
[ "$BG" = 1 ] && args=(-f "${args[@]}")
info=()
for e in "${ENG[@]}"; do
  case "$e" in
    adminer) args+=(-L "127.0.0.1:${LOCAL_ADMINER}:127.0.0.1:${ADMINER_PORT}")
      info+=("adminer    http://127.0.0.1:${LOCAL_ADMINER}  (server: postgres / mysql / mariadb)") ;;
    *) [ -n "$PIP" ] || die "--private-ip is required for $e"
      case "$e" in
        postgres)  l=$LOCAL_PG; r=$PG_PORT ;;
        pgbouncer) l=$LOCAL_PGBOUNCER; r=$PGBOUNCER_PORT ;;
        mysql)     l=$LOCAL_MYSQL; r=$MYSQL_PORT ;;
        mariadb)   l=$LOCAL_MARIADB; r=$MARIADB_PORT ;;
      esac
      args+=(-L "127.0.0.1:${l}:${PIP}:${r}")
      info+=("$(printf '%-10s 127.0.0.1:%s -> %s:%s' "$e" "$l" "$PIP" "$r")") ;;
  esac
done
args+=("$HOST")

if [ "$PRINT" = 1 ]; then printf 'ssh'; printf ' %q' "${args[@]}"; echo; exit 0; fi
printf 'Tunnels via %s:\n' "$HOST"; printf '  %s\n' "${info[@]}"
[ "$BG" = 1 ] || echo "Ctrl-C to close."
exec ssh "${args[@]}"
