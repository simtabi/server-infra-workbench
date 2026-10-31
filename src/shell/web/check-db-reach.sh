#!/usr/bin/env bash
# =============================================================================
#  check-db-reach.sh - can this (web) server reach the DB server's ports?
# =============================================================================
#  Plain TCP probes with bash's /dev/tcp; needs no client tools, no passwords.
#  Run it on the web server (or from your workstation with --remote ALIAS).
#
#    check-db-reach.sh 10.0.0.5                     # 5432 6432 3306 3307
#    check-db-reach.sh 10.0.0.5 5432 6432
#    check-db-reach.sh --env /home/ploi/example.com-shared/.env   # DB_HOST + DB_PORT
#    check-db-reach.sh --remote web-alias 10.0.0.5
#
#  Exit 0 if every port answers, 1 otherwise.
# =============================================================================
set -euo pipefail
die() { printf '!! %s\n' "$*" >&2; exit 2; }
if [ "${1:-}" = "--remote" ]; then
  [ -n "${2:-}" ] || die "--remote needs an ssh alias"
  alias_="$2"; shift 2
  exec ssh -o BatchMode=yes "$alias_" bash -s -- "$@" < "$0"
fi
if [ "${1:-}" = "--env" ]; then
  [ -r "${2:-}" ] || die "cannot read ${2:-<missing>}"
  host="$(grep -E '^DB_HOST=' "$2" | tail -1 | cut -d= -f2- | tr -d '"')"
  set -- "$host" "$(grep -E '^DB_PORT=' "$2" | tail -1 | cut -d= -f2- | tr -d '"')"
fi
case "${1:-}" in ""|-h|--help) sed -n '2,/^# =====/{/^# =====/d;s/^#  \{0,1\}//;p}' "$0"; exit 0 ;; esac
host="$1"; shift
[ $# -gt 0 ] || set -- 5432 6432 3306 3307
rc=0; TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 3"
for p in "$@"; do
  if ${TO:-} bash -c "exec 3<>/dev/tcp/$host/$p" 2>/dev/null; then echo "ok      $host:$p"
  else echo "CLOSED  $host:$p"; rc=1; fi
done
[ "$rc" = 0 ] || echo "hint: on the DB server check 'docker ps', 'ss -tln' and 'sudo ufw status' (VPC_CIDR must include this server)"
exit "$rc"
