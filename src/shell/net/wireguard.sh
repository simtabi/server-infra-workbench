#!/usr/bin/env bash
# =============================================================================
#  wireguard.sh - an encrypted WireGuard tunnel between two servers, e.g. a web
#  server and a DB server in different DigitalOcean regions (VPCs are per region)
# =============================================================================
#  Run it from your workstation. It plans first and changes nothing until you
#  confirm (--yes or type yes). Each server makes its own private key; private
#  keys never leave the server and are never printed (the config loads the key
#  with PostUp, so it isn't even in wg0.conf). Public keys travel between the
#  servers through this script's memory and show only as a short fingerprint.
#  ufw opens the WireGuard port to the other server's public IP only, and (on
#  the DB side) the DB ports to the peer's tunnel IP only. See docs/cross-region.md.
#
#  USAGE
#    wireguard.sh setup --host <db-ssh> --peer <web-ssh> [--dry-run|--yes]
#    wireguard.sh status --host <ssh> [--ping TUNNEL_IP] [--iface wg0]
#                                            handshake age, transfer, ping (no keys)
#    wireguard.sh remove --host <ssh> [--yes]  stop + disable; config kept as .bak
#
#  SETUP OPTIONS
#    --host H           the DB side (gets the DB-port rules); ssh alias or user@host
#    --peer P           the app side
#    --host-ip IP       tunnel IP of --host (default 10.200.0.1)
#    --peer-ip IP       tunnel IP of --peer (default 10.200.0.2); /24 around them
#    --host-endpoint IP / --peer-endpoint IP   public IPs (default: detected)
#    --port N           UDP listen port (default 51820)
#    --db-ports a,b     ports the peer may reach through the tunnel (default 5432,6432)
#    --iface NAME       interface (default wg0)
#    --ploi-ufw         also add ufw rules on a Ploi server (default: print the
#                       rule to add in Ploi's Network tab, because Ploi owns ufw)
#    --dry-run, -n  --yes, -y  -h, --help
#
#  AFTER SETUP (printed at the end)
#    DB manager config: EXTRA_BIND_IPS=<host-ip>  PEER_REGIONS=<peer region>,
#    then `upgrade --dry-run` / `upgrade`; the app's DB_HOST=<host-ip>.
#    DO cloud firewall: allow UDP <port> from each server's public IP.
# =============================================================================
# shellcheck disable=SC2015  # `check && ok || bad` is the idiom (ok never fails)
set -euo pipefail
TOOL=wireguard
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

is_ip() { local IFS=. x; [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; for x in $1; do [ "$x" -le 255 ] || return 1; done; }
is_key() { [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; }
fp() { printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12; }

# run_on HOST SUBCOMMAND ARGS... : the server side of this script, on HOST over ssh
# (tests: SIWO_WG_LOCAL=<dir> runs it locally with SIWO_SYSROOT=<dir>/<host>)
run_on() { local h="$1"; shift
  if [ -n "${SIWO_WG_LOCAL:-}" ]; then SIWO_SYSROOT="$SIWO_WG_LOCAL/$h" bash "$0" "$@"
  else REMOTE_NOTTY=1 remote "$h" "$0" "$@"; fi
}

# ---------------------------------------------------------------- server side
conf_path() { echo "$R/etc/wireguard/$1.conf"; }
key_path()  { echo "$R/etc/wireguard/$1.key"; }

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
cidr_overlap() { # a.b.c.d/n e.f.g.h/m -> 0 when the two ranges share an address
  local n1="${1#*/}" n2="${2#*/}" m i1 i2
  [[ "$n1" =~ ^[0-9]+$ && "$n2" =~ ^[0-9]+$ ]] || return 1
  is_ip "${1%/*}" && is_ip "${2%/*}" || return 1
  m=$(( n1 < n2 ? n1 : n2 ))
  [ "$m" -gt 0 ] || return 0
  i1="$(ip2int "${1%/*}")"; i2="$(ip2int "${2%/*}")"
  [ $(( (i1 ^ i2) >> (32 - m) )) -eq 0 ]
}
srv_info() { # key=value lines; read-only
  local ip region="" ;
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true)"
  have curl && region="$(curl -fsS --max-time 2 "${METADATA_URL:-http://169.254.169.254/metadata/v1}/region" 2>/dev/null || true)"
  [[ "$region" =~ ^[a-z]{3}[0-9]$ ]] || region=unknown
  echo "public_ip=${ip:-unknown}"; echo "region=$region"
  echo "wg=$(have wg && echo installed || echo missing)"
  echo "ploi=$(ploi_managed && echo 1 || echo 0)"
  echo "conf=$([ -f "$(conf_path "$IFACE")" ] && echo present || echo absent)"
  # every IPv4 network on the host except the tunnel itself: setup refuses a tunnel /24 that overlaps one
  echo "nets=$(ip -4 -o addr show 2>/dev/null | awk -v w="$IFACE" '$2 != w {print $4}' | tr '\n' ' ')"
}

srv_keygen() { # prints the PUBLIC key only
  have wg || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q wireguard-tools >/dev/null || die "apt-get install wireguard-tools failed"; }
  local k; k="$(key_path "$IFACE")"
  mkdir -p "$(dirname "$k")"; chmod 700 "$(dirname "$k")"
  if [ ! -s "$k" ]; then (umask 077; wg genkey > "$k"); audit succeeded "keygen iface=$IFACE"; fi
  chmod 600 "$k"
  wg pubkey < "$k"
}

srv_apply() {
  is_ip "$SELF_IP" && is_ip "$PEER_IP" && is_ip "$PEER_EP" || CODE=2 die "apply needs --self-ip, --peer-ip and --peer-endpoint"
  is_key "$PEER_KEY" || CODE=2 die "apply: --peer-pubkey is not a WireGuard public key"
  [ -s "$(key_path "$IFACE")" ] || die "no $(key_path "$IFACE"): run keygen first"
  lock
  write_file "$(conf_path "$IFACE")" 600 <<CONF
# Managed by server-infra-workbench wireguard.sh - re-run setup instead of editing.
# The private key stays in /etc/wireguard/$IFACE.key (600) and is loaded by PostUp.
[Interface]
Address = $SELF_IP/24
ListenPort = $PORT
PostUp = wg set %i private-key /etc/wireguard/$IFACE.key

[Peer]
PublicKey = $PEER_KEY
Endpoint = $PEER_EP:$PORT
AllowedIPs = $PEER_IP/32
PersistentKeepalive = 25
CONF
  ok "$(conf_path "$IFACE") written (600)"
  if ploi_managed && [ "$PLOI_UFW" != 1 ]; then
    todo "Ploi server: add in Ploi -> Server -> Network: UDP $PORT from $PEER_EP (Ploi owns ufw)"
    [ -z "$DB_PORTS" ] || todo "Ploi server: and TCP ${DB_PORTS} from $PEER_IP"
  elif have ufw; then
    ufw status | grep -E "^$PORT/udp +ALLOW( IN)? +${PEER_EP//./\\.}( |$)" >/dev/null \
      || ufw allow proto udp from "$PEER_EP" to any port "$PORT" comment 'vsw wireguard' >/dev/null
    ok "ufw: UDP $PORT from $PEER_EP only"
    local p; for p in ${DB_PORTS//,/ }; do
      ufw status | grep -E "^$p/tcp on $IFACE +ALLOW( IN)? +${PEER_IP//./\\.}( |$)" >/dev/null \
        || ufw allow in on "$IFACE" proto tcp from "$PEER_IP" to any port "$p" comment 'vsw wireguard db' >/dev/null
      ok "ufw: TCP $p on $IFACE from $PEER_IP only"
    done
  else warn "ufw not installed: open UDP $PORT from $PEER_EP in the DO cloud firewall"; fi
  if [ -n "$DB_PORTS" ] && have docker; then
    # Docker publishes the DB ports on the tunnel IP, so it must start after the tunnel
    write_file "$R/etc/systemd/system/docker.service.d/10-vsw-wireguard.conf" 644 <<UNIT
[Unit]
After=wg-quick@$IFACE.service
Wants=wg-quick@$IFACE.service
UNIT
    ok "docker starts after wg-quick@$IFACE"
  fi
  systemctl daemon-reload
  systemctl enable "wg-quick@$IFACE" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@$IFACE" || die "wg-quick@$IFACE failed to start (journalctl -u wg-quick@$IFACE)"
  audit succeeded "apply iface=$IFACE self=$SELF_IP peer=$PEER_IP endpoint=$PEER_EP peerkey=$(fp "$PEER_KEY")"
  ok "wg-quick@$IFACE up"
}

srv_status() {
  have wg || { warn "wireguard-tools not installed"; return 0; }
  local hs now age
  hs="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1 || true)"
  now="$(date +%s)"
  if [ -z "$hs" ]; then bad "$IFACE: not up"; return 0; fi
  if [ "$hs" = 0 ]; then bad "$IFACE: no handshake yet (endpoint, UDP $PORT in both firewalls, keys)"
  else age=$((now - hs)); if [ "$age" -le 180 ]; then ok "$IFACE: last handshake ${age}s ago"; else warn "$IFACE: last handshake ${age}s ago"; fi; fi
  wg show "$IFACE" transfer 2>/dev/null | awk '{printf "  info  received %s B, sent %s B\n", $2, $3}'
  [ -z "$PING_IP" ] || { ping -c 2 -W 2 "$PING_IP" >/dev/null 2>&1 && ok "ping $PING_IP through the tunnel" || bad "no ping reply from $PING_IP"; }
}

srv_remove() {
  lock
  systemctl disable --now "wg-quick@$IFACE" >/dev/null 2>&1 || true
  local c; c="$(conf_path "$IFACE")"
  [ ! -f "$c" ] || { backup "$c"; rm -f "$c"; }
  rm -f "$R/etc/systemd/system/docker.service.d/10-vsw-wireguard.conf"; systemctl daemon-reload || true
  audit succeeded "remove iface=$IFACE"
  ok "$IFACE stopped and disabled; config backed up (key kept in $(key_path "$IFACE"); ufw rules: ufw status numbered)"
}

# ---------------------------------------------------------------- workstation side
kv() { sed -n "s/^$1=//p" <<<"$2" | head -n1; }

ws_setup() {
  [ -n "$HOST" ] && [ -n "$PEER" ] || CODE=2 die "setup needs --host <db> and --peer <web>"
  [ "$HOST" != "$PEER" ] || CODE=2 die "--host and --peer must differ"
  is_ip "$HOST_IP" && is_ip "$PEER_IP" || CODE=2 die "--host-ip/--peer-ip must be IPv4 addresses"
  [ "$HOST_IP" != "$PEER_IP" ] || CODE=2 die "--host-ip and --peer-ip must differ"
  [ "${HOST_IP%.*}" = "${PEER_IP%.*}" ] || CODE=2 die "--host-ip and --peer-ip must share a /24"
  local hi pi
  say "Reading both servers (read-only)..."
  hi="$(run_on "$HOST" info --iface "$IFACE")" || die "cannot read $HOST"
  pi="$(run_on "$PEER" info --iface "$IFACE")" || die "cannot read $PEER"
  [ -n "$HOST_EP" ] || HOST_EP="$(kv public_ip "$hi")"; [ -n "$PEER_EP" ] || PEER_EP="$(kv public_ip "$pi")"
  is_ip "$HOST_EP" || CODE=2 die "could not detect $HOST's public IP; pass --host-endpoint"
  is_ip "$PEER_EP" || CODE=2 die "could not detect $PEER's public IP; pass --peer-endpoint"
  local hr pr n; hr="$(kv region "$hi")"; pr="$(kv region "$pi")"
  # rehearsal finding: the default 10.200.0.0/24 was the VPC range of the test droplets; a tunnel on top of
  # a network the host already has breaks both. Refuse it here, before anything changes.
  for n in $(kv nets "$hi") $(kv nets "$pi"); do
    if cidr_overlap "${HOST_IP%.*}.0/24" "$n"; then
      CODE=2 die "tunnel ${HOST_IP%.*}.0/24 overlaps $n on one of the servers; pick another /24, e.g. --host-ip 10.250.0.1 --peer-ip 10.250.0.2"
    fi
  done
  say ""
  say "Plan: WireGuard $IFACE between $HOST and $PEER (UDP $PORT)"
  say "  $HOST  region $hr  endpoint $HOST_EP  tunnel $HOST_IP  wireguard-tools $(kv wg "$hi")  config $(kv conf "$hi")"
  say "  $PEER  region $pr  endpoint $PEER_EP  tunnel $PEER_IP  wireguard-tools $(kv wg "$pi")  config $(kv conf "$pi")"
  [ "$hr" != "$pr" ] || [ "$hr" = unknown ] || say "  note: both are in $hr - a shared VPC is simpler than a tunnel (docs/cross-region.md)"
  say "  1. each server: install wireguard-tools, generate its own key in /etc/wireguard/$IFACE.key (600, never printed)"
  say "  2. each server: /etc/wireguard/$IFACE.conf (600) with only the other server as peer; wg-quick@$IFACE enabled"
  say "  3. ufw on $HOST: UDP $PORT from $PEER_EP; TCP ${DB_PORTS:-none} on $IFACE from $PEER_IP"
  say "     ufw on $PEER: UDP $PORT from $HOST_EP$( [ "$(kv ploi "$pi")" = 1 ] && [ "$PLOI_UFW" != 1 ] && echo ' (Ploi server: printed for the Ploi panel instead)')"
  say "  4. $HOST: docker starts after the tunnel (the DB ports get published on $HOST_IP)"
  say "  5. check: handshake and ping both ways"
  if [ "$DRY" = 1 ]; then say ""; say "dry run: nothing changed"; return 0; fi
  confirm "Set up the tunnel on $HOST and $PEER"
  local hk pk
  hk="$(run_on "$HOST" keygen --iface "$IFACE" | tail -n1)"; is_key "$hk" || die "$HOST: keygen did not return a public key"
  pk="$(run_on "$PEER" keygen --iface "$IFACE" | tail -n1)"; is_key "$pk" || die "$PEER: keygen did not return a public key"
  say "public keys: $HOST $(fp "$hk")..., $PEER $(fp "$pk")... (fingerprints)"
  local pu=(); [ "$PLOI_UFW" = 1 ] && pu=(--ploi-ufw)
  run_on "$HOST" apply --iface "$IFACE" --port "$PORT" --self-ip "$HOST_IP" --peer-ip "$PEER_IP" --peer-endpoint "$PEER_EP" \
    --peer-pubkey "$pk" --db-ports "$DB_PORTS" "${pu[@]+"${pu[@]}"}"
  run_on "$PEER" apply --iface "$IFACE" --port "$PORT" --self-ip "$PEER_IP" --peer-ip "$HOST_IP" --peer-endpoint "$HOST_EP" \
    --peer-pubkey "$hk" --db-ports "" "${pu[@]+"${pu[@]}"}"
  run_on "$PEER" status --iface "$IFACE" --ping "$HOST_IP" || true
  audit succeeded "setup host=$HOST peer=$PEER"
  cat <<NEXT

Next:
  1. DO cloud firewall: allow UDP $PORT from $PEER_EP on $HOST and from $HOST_EP on $PEER.
  2. DB manager config on $HOST: EXTRA_BIND_IPS=$HOST_IP  PEER_REGIONS=$pr
     then: sudo /root/docker-db-server-manager.sh upgrade --dry-run, then upgrade
  3. App .env on $PEER: DB_HOST=$HOST_IP (PgBouncer 6432 or Postgres 5432)
  4. Check: bin/siwo web check-db-reach --remote $PEER $HOST_IP 6432 5432
NEXT
}

# ---------------------------------------------------------------- arguments
CMD="${1:-}"; [ $# -gt 0 ] && shift
HOST="" PEER="" HOST_IP=10.200.0.1 PEER_IP=10.200.0.2 HOST_EP="" PEER_EP="" PORT=51820 DB_PORTS=5432,6432
IFACE=wg0 PLOI_UFW=0 SELF_IP="" PEER_KEY="" PING_IP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --peer) PEER="${2:?}"; shift 2 ;;
    --host-ip) HOST_IP="${2:?}"; shift 2 ;;
    --peer-ip) PEER_IP="${2:?}"; shift 2 ;;
    --host-endpoint) HOST_EP="${2:?}"; shift 2 ;;
    --peer-endpoint) PEER_EP="${2:?}"; shift 2 ;;
    --self-ip) SELF_IP="${2:?}"; shift 2 ;;
    --peer-pubkey) PEER_KEY="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --db-ports) DB_PORTS="${2-}"; shift 2 ;;
    --iface) IFACE="${2:?}"; shift 2 ;;
    --ping) PING_IP="${2:?}"; shift 2 ;;
    --ploi-ufw) PLOI_UFW=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
[[ "$IFACE" =~ ^[a-z][a-z0-9]{0,14}$ ]] || CODE=2 die "--iface must look like wg0"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || CODE=2 die "--port must be 1-65535"
[[ -z "$DB_PORTS" || "$DB_PORTS" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || CODE=2 die "--db-ports takes ports like 5432,6432"

case "$CMD" in
  setup) ws_setup ;;
  status)
    if [ -n "$HOST" ]; then run_on "$HOST" status --iface "$IFACE" ${PING_IP:+--ping "$PING_IP"}; else srv_status; summary; fi ;;
  remove)
    if [ -n "$HOST" ]; then
      [ "$DRY" = 1 ] && { say "plan: stop and disable wg-quick@$IFACE on $HOST, back up its config"; exit 0; }
      confirm "Remove the tunnel $IFACE on $HOST"; run_on "$HOST" remove --iface "$IFACE" --yes
    else srv_remove; fi ;;
  info) srv_info ;;
  keygen) srv_keygen ;;
  apply) srv_apply; summary ;;
  ""|-h|--help|help) usage ;;
  *) CODE=2 die "unknown command: $CMD (setup, status, remove)" ;;
esac
