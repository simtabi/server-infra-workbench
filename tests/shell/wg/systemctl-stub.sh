#!/usr/bin/env bash
# systemctl stand-in for wg-it containers (no systemd): only what wireguard.sh calls.
set -euo pipefail
act="${1:-}"; shift || true
[ "${1:-}" = --now ] && { now=1; shift; } || now=0
unit="${1:-}"; iface="${unit#wg-quick@}"; iface="${iface%.service}"
up()   { ip link show "$iface" >/dev/null 2>&1 || wg-quick up "$iface"; }
down() { ! ip link show "$iface" >/dev/null 2>&1 || wg-quick down "$iface"; }
echo "$(date +%s) $act $now $unit" >> /var/log/systemctl-stub.log
case "$act" in
  daemon-reload|enable) exit 0 ;;
  restart) [[ "$unit" == wg-quick@* ]] && { down; up; } ;;
  start) [[ "$unit" == wg-quick@* ]] && up ;;
  stop) [[ "$unit" == wg-quick@* ]] && down ;;
  disable) [ "$now" = 1 ] && [[ "$unit" == wg-quick@* ]] && down; exit 0 ;;
  is-active) ip link show "$iface" >/dev/null 2>&1 ;;
  *) echo "systemctl stub: $act not supported" >&2; exit 1 ;;
esac
