#!/usr/bin/env bash
# db-tunnel.sh - open an SSH tunnel from your workstation to a DB server whose
# ports listen only on the private VPC IP (and Adminer only on 127.0.0.1).
#
# Usage: db-tunnel.sh [options] <engine>...
#   engines: postgres pgbouncer mysql mariadb adminer all
# Options:
#   --host HOST      SSH destination: user@public-ip or an ~/.ssh/config alias (or DB_TUNNEL_HOST, SIWO_DB_SSH_HOST)
#   --private-ip IP  DB server private VPC IP the ports bind to (or DB_PRIVATE_IP, SIWO_DB_PRIVATE_IP)
#   --env-file F     read SIWO_DB_SSH_HOST, SIWO_DB_PRIVATE_IP and SIWO_DB_LOCAL_* from F (default: $SIWO_ENV_FILE, else the repo .env
#                    when it exists; never sourced, no password is read)
#   --background     fork into the background (ssh -f); stop with: pkill -f 'ssh -N .*<host>'
#   --print          print the ssh command, don't run it
#   -h|--help
# Local ports (override with env or SIWO_DB_LOCAL_* in the env file): LOCAL_PG=15432 LOCAL_PGBOUNCER=16432
#   LOCAL_MYSQL=13306 LOCAL_MARIADB=13307 LOCAL_ADMINER=8081
# Connecting DB clients (TablePlus, DBeaver, DataGrip, psql, mysql): docs/databases/connecting-local-clients.md
# Remote ports match the manager defaults (PG_PORT=5432 PGBOUNCER_PORT=6432
#   MYSQL_PORT=3306 MARIADB_PORT=3307 ADMINER_PORT=8081); override with the same names.
#
# Example:
#   src/shell/tunnels/db-tunnel.sh --host ploi@203.0.113.10 --private-ip 10.0.0.5 postgres adminer
set -euo pipefail

HOST="${DB_TUNNEL_HOST:-${SIWO_DB_SSH_HOST:-}}"; PIP="${DB_PRIVATE_IP:-${SIWO_DB_PRIVATE_IP:-}}"; BG=0; PRINT=0; ENG=()
ENVF="${SIWO_ENV_FILE:-$(cd "$(dirname "$0")/../../.." && pwd)/.env}"
PG_PORT="${PG_PORT:-5432}"; PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
MYSQL_PORT="${MYSQL_PORT:-3306}"; MARIADB_PORT="${MARIADB_PORT:-3307}"; ADMINER_PORT="${ADMINER_PORT:-8081}"
PRESET="$(for v in LOCAL_PG LOCAL_PGBOUNCER LOCAL_MYSQL LOCAL_MARIADB LOCAL_ADMINER; do [ -z "${!v:-}" ] || printf '%s ' "$v"; done)"
LOCAL_PG="${LOCAL_PG:-15432}"; LOCAL_PGBOUNCER="${LOCAL_PGBOUNCER:-16432}"
LOCAL_MYSQL="${LOCAL_MYSQL:-13306}"; LOCAL_MARIADB="${LOCAL_MARIADB:-13307}"; LOCAL_ADMINER="${LOCAL_ADMINER:-8081}"

# usage: the header comment block (up to the first code line), minus shellcheck directives
usage() { awk 'NR==1{next} !/^#/{exit} /^# shellcheck /{next} {sub(/^# ?/,""); print}' "$0"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }
env_get() { # file key -> value of KEY=VALUE (quotes and trailing comments stripped); never sources the file
  [ -f "$1" ] || return 0
  awk -v k="$2" -F= '$0 !~ /^[[:space:]]*#/ && $1 == k { v = substr($0, length(k) + 2); sub(/[[:space:]]+#.*$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }' "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --private-ip) PIP="${2:-}"; shift 2 ;;
    --env-file) ENVF="${2:-}"; [ -f "$ENVF" ] || die "no such env file: $ENVF"; shift 2 ;;
    --background) BG=1; shift ;;
    --print) PRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    all) ENG+=(postgres pgbouncer mysql mariadb adminer); shift ;;
    postgres|pgbouncer|mysql|mariadb|adminer) ENG+=("$1"); shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
HOST="${HOST:-$(env_get "$ENVF" SIWO_DB_SSH_HOST)}"; PIP="${PIP:-$(env_get "$ENVF" SIWO_DB_PRIVATE_IP)}"
for v in PG PGBOUNCER MYSQL MARIADB ADMINER; do # SIWO_DB_LOCAL_<X> from the env file unless LOCAL_<X> was in the environment
  e="$(env_get "$ENVF" "SIWO_DB_LOCAL_$v")"
  in_env=0; case " $PRESET " in *" LOCAL_$v "*) in_env=1 ;; esac
  if [ -n "$e" ] && [ "$in_env" = 0 ]; then [[ "$e" =~ ^[0-9]{2,5}$ ]] || die "SIWO_DB_LOCAL_$v must be a port"; printf -v "LOCAL_$v" '%s' "$e"; fi
done
case "$HOST$PIP" in *"<"*|*">"*) die "replace the <placeholders> (host / private IP) first" ;; esac
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
