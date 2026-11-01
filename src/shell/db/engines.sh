#!/usr/bin/env bash
# engines.sh - switch DB engines on/off on the DB server from your workstation, driven by the
# SIWO_DB_ENABLE_* toggles in the workbench .env. The engines that stay on keep running (no restart):
# the server runs `docker-db-server-manager.sh engines apply`, which touches only the changed services.
#
# Usage: engines.sh status|plan|apply [options]
#   status          what runs on the server: setting, container, port, data volume (read-only)
#   plan            what apply would change (engines apply --dry-run; changes nothing)
#   apply           stop/start the engines whose toggle differs; the server asks you to type APPLY
# Options:
#   --env-file F    settings file (default: .env at the repo root, or SIWO_ENV_FILE). Read with awk, never
#                   sourced; no password is sent. Its SIWO_DB_* server keys also become the server config
#                   (see remote-run.sh --help); --config FILE overrides that, --no-config skips it
#   --host H        user@ip, user@host or an ssh alias of the DB server (default: SIWO_DB_SSH_HOST)
#   -i, --identity KEY  private key for ssh, used alone (default: SIWO_DB_SSH_IDENTITY)
#   --expect-ip IP  its private IP, the wrong-server guard (default: SIWO_DB_PRIVATE_IP)
#   --dry-run       same as plan
#   --purge         apply: also delete the data volumes of engines turned off (typed confirmation; backup first)
#   --no-upload     use the manager already in /root (default: upload this checkout's manager)
#   --sudo MODE     auto (default) | nopasswd | prompt: see remote-run.sh --help (sudo asks once, over ssh -t)
#   --print         print the remote-run command, connect to nothing
#   -h|--help
# A toggle missing from the file is not sent: the server keeps its own setting for that engine.
# The server keeps ENABLE_* in /opt/db/.env (and in /etc/docker-db-server-manager.conf when one is installed;
# the .env wins); apply updates every file that holds the key, with a dated .bak-* copy.
# Example (a Postgres-only server): set SIWO_DB_ENABLE_MYSQL=0 and SIWO_DB_ENABLE_MARIADB=0, then
#   bin/siwo db engines plan && bin/siwo db engines apply
#   bin/siwo db engines plan  --host user@203.0.113.10 -i ~/.ssh/db-key --expect-ip 10.0.0.5
#   bin/siwo db engines apply --host user@203.0.113.10 -i ~/.ssh/db-key --expect-ip 10.0.0.5
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"

usage() { awk 'NR==1{next} !/^#/{exit} /^# shellcheck /{next} {sub(/^# ?/,""); print}' "$0"; }
die() { printf '!! %s\n' "$*" >&2; exit 2; }
env_get() { # file key -> value of KEY=VALUE (quotes stripped, comments ignored); never sources the file
  [ -f "$1" ] || return 0
  awk -v k="$2" -F= '$0 !~ /^[[:space:]]*#/ && $1 == k { v = substr($0, length(k) + 2); sub(/[[:space:]]+#.*$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }' "$1"
}

ACT="" ENVF="${SIWO_ENV_FILE:-$ROOT/.env}" CONFIG="" NOCONF=0 HOST="" EXPECT="" IDENT="" SUDO="" PURGE=0 NOUP=0 PRINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    status|plan|apply) ACT="$1" ;;
    --env-file) ENVF="${2:-}"; shift ;;
    --host) HOST="${2:-}"; shift ;;
    --expect-ip) EXPECT="${2:-}"; shift ;;
    -i|--identity) IDENT="${2:-}"; shift ;;
    --sudo) SUDO="${2:-}"; shift ;;
    --config) CONFIG="${2:-}"; shift ;;
    --no-config) NOCONF=1 ;;
    --dry-run) ACT=plan ;;
    --purge) PURGE=1 ;;
    --no-upload) NOUP=1 ;;
    --print) PRINT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac; shift
done
[ -n "$ACT" ] || { usage >&2; die "name an action: status, plan or apply"; }
[ -z "$ENVF" ] || [ -f "$ENVF" ] || [ "$ENVF" = "$ROOT/.env" ] || die "no such env file: $ENVF"
HOST="${HOST:-${SIWO_DB_SSH_HOST:-$(env_get "$ENVF" SIWO_DB_SSH_HOST)}}"
EXPECT="${EXPECT:-${SIWO_DB_PRIVATE_IP:-$(env_get "$ENVF" SIWO_DB_PRIVATE_IP)}}"
EXPECT="${EXPECT:-$(env_get "$ENVF" SIWO_DB_EXPECTED_PRIVATE_IP)}"
IDENT="${IDENT:-${SIWO_DB_SSH_IDENTITY:-$(env_get "$ENVF" SIWO_DB_SSH_IDENTITY)}}"
[ -n "$HOST" ] || die "no DB server: --host user@ip (or an ssh alias) or SIWO_DB_SSH_HOST in $ENVF"
[ -n "$EXPECT" ] || die "no private IP for the wrong-server guard: --expect-ip IP or SIWO_DB_PRIVATE_IP in $ENVF"
kd=""; [ -z "$IDENT" ] || kd=", key '$IDENT'"
case "$HOST$EXPECT$IDENT" in *"<"*|*">"*) die "still a <placeholder>: host '$HOST', ip '$EXPECT'$kd. Pass --host user@ip --expect-ip IP, or fill SIWO_DB_SSH_HOST / SIWO_DB_PRIVATE_IP in $ENVF" ;; esac

sets=""
for k in POSTGRES PGBOUNCER MYSQL MARIADB ADMINER; do
  v="$(env_get "$ENVF" "SIWO_DB_ENABLE_$k")"
  [ -n "$v" ] || continue
  case "$v" in 0|1) sets="$sets --set ENABLE_$k=$v" ;; *) die "SIWO_DB_ENABLE_$k in $ENVF must be 0 or 1 (got '$v')" ;; esac
done
case "$ACT" in
  status) cmd="engines status" ;;
  plan) cmd="engines apply$sets --dry-run" ;;
  apply) cmd="engines apply$sets$([ "$PURGE" = 1 ] && echo ' --purge' || true)" ;;
esac
[ "$ACT" = status ] || [ -n "$sets" ] || echo "note: no SIWO_DB_ENABLE_* in $ENVF; the server's own settings are used"
args=(--host "$HOST" --expect-ip "$EXPECT"); [ "$NOUP" = 1 ] && args+=(--no-upload)
[ -z "$IDENT" ] || args+=(--identity "$IDENT"); [ -z "$SUDO" ] || args+=(--sudo "$SUDO")
[ ! -f "$ENVF" ] || args+=(--env-file "$ENVF"); [ -z "$CONFIG" ] || args+=(--config "$CONFIG"); [ "$NOCONF" = 0 ] || args+=(--no-config)
if [ "$PRINT" = 1 ]; then printf '%q' "$HERE/remote-run.sh"; printf ' %q' "${args[@]}" -- "$cmd"; echo; exit 0; fi
exec "$HERE/remote-run.sh" "${args[@]}" -- "$cmd"
