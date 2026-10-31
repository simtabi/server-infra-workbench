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
#    check-db-reach.sh --db-region nyc1 10.0.0.5       # also compare regions
#
#  On a DigitalOcean droplet it also reads this droplet's region and VPC from
#  the metadata service and warns when the DB address can't be in the same VPC
#  (VPCs are per region: docs/cross-region.md).
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
DB_REGION=""
if [ "${1:-}" = "--db-region" ]; then
  [[ "${2:-}" =~ ^[a-z]{3}[0-9]$ ]] || die "--db-region needs a region slug like nyc1"
  DB_REGION="$2"; shift 2
fi
case "${1:-}" in ""|-h|--help) awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; exit 0 ;; esac
host="$1"; shift
[ $# -gt 0 ] || set -- 5432 6432 3306 3307

# ---- region / VPC sanity (DigitalOcean metadata; silent elsewhere) ----------------
MD="${METADATA_URL:-http://169.254.169.254/metadata/v1}"
md() { command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "$MD/$1" 2>/dev/null; }
i2n() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
private() { is_ip "$1" || return 1; local n; n="$(i2n "$1")"
  [ $(( n >> 24 )) -eq 10 ] || [ $(( n >> 20 )) -eq $(( (172 << 4) + 1 )) ] || [ $(( n >> 16 )) -eq $(( (192 << 8) + 168 )) ]; }
region="$(md region || true)"; [[ "$region" =~ ^[a-z]{3}[0-9]$ ]] || region=""
if [ -n "$region" ]; then
  my_ip="$(md interfaces/private/0/ipv4/address || true)"; mask="$(md interfaces/private/0/ipv4/netmask || true)"
  echo "this droplet: region $region${my_ip:+, VPC address $my_ip/$mask}"
  if [ -n "$DB_REGION" ] && [ "$DB_REGION" != "$region" ]; then
    echo "WARNING: the DB is in $DB_REGION and this server in $region. DO VPCs are per region, so private"
    echo "         addresses only route between them with VPC peering: same region, VPC peering, WireGuard, or TLS over a"
    echo "         public IP (docs/cross-region.md)"
  fi
  if is_ip "$host" && is_ip "${my_ip:-}" && is_ip "${mask:-}"; then
    m="$(i2n "$mask")"
    if private "$host" && [ $(( $(i2n "$host") & m )) -ne $(( $(i2n "$my_ip") & m )) ] && [[ "$host" != 10.200.* ]]; then
      echo "WARNING: $host is a private address outside this droplet's VPC ($my_ip/$mask). It is probably in another"
      echo "         VPC or region; it is only reachable if the VPCs are peered or a tunnel routes it (docs/cross-region.md)"
    elif ! private "$host"; then
      echo "note: $host is a public address: the DB traffic leaves the VPC. Use the DB's private IP, or TLS (sslmode=verify-full)"
      echo "      plus a cloud-firewall allowlist (docs/cross-region.md)"
    fi
  fi
fi
rc=0; TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 3"
for p in "$@"; do
  if ${TO:-} bash -c "exec 3<>/dev/tcp/$host/$p" 2>/dev/null; then echo "ok      $host:$p"
  else echo "CLOSED  $host:$p"; rc=1; fi
done
[ "$rc" = 0 ] || { echo "hint: on the DB server check 'docker ps', 'ss -tln' and 'sudo ufw status' (VPC_CIDR must include this server)"
  echo "      and that both droplets are in the same region and VPC (or a WireGuard tunnel is up: wg show)"; }
exit "$rc"
