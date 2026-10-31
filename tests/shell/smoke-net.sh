#!/usr/bin/env bash
# Offline tests for src/shell/net/wireguard.sh: two fake servers (VSW_WG_LOCAL dirs) and stub
# wg/ufw/systemctl/ip/curl; nothing touches this machine's network or /etc.
# shellcheck disable=SC2015,SC2016  # `check && ok || fail`; stub bodies are literal shell
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
stub() { printf '#!/bin/sh\necho "%s $* [${VSW_SYSROOT##*/}]" >> "%s/calls"\n%s\n' "$1" "$T" "${2:-}" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
mkdir -p "$T/bin"
for c in systemctl apt-get docker ping; do stub "$c"; done
stub ufw 'case "$1" in
  status) cat "$VSW_SYSROOT/ufw.status" 2>/dev/null || true;;
  allow) echo "$*" >> "$VSW_SYSROOT/ufw"
    if [ "$2" = in ]; then echo "${12}/tcp on $4    ALLOW IN    $8" >> "$VSW_SYSROOT/ufw.status"
    else echo "${9}/udp    ALLOW IN    $5    # vsw" >> "$VSW_SYSROOT/ufw.status"; fi;;
esac'
stub ip 'echo "1.1.1.1 via 192.0.2.254 dev eth0 src $(cat "$VSW_SYSROOT/pubip") uid 0"'
stub curl 'cat "$VSW_SYSROOT/region"'
stub wg 'case "$1" in
  genkey) echo "PRIVATE-$(cat "$VSW_SYSROOT/pubip")-SECRET";;
  pubkey) printf "%sA=\n" "$( (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-42)";;
  show) [ "$3" = latest-handshakes ] && echo "KEY $(date +%s)"; [ "$3" = transfer ] && echo "KEY 10 20";;
esac'
fresh() { rm -rf "$T/srv" "$T/calls"; mkdir -p "$T/srv/db" "$T/srv/web"; : > "$T/calls"
  echo 203.0.113.10 > "$T/srv/db/pubip"; echo ams3 > "$T/srv/db/region"
  echo 198.51.100.20 > "$T/srv/web/pubip"; echo nyc1 > "$T/srv/web/region"; }
export PATH="$T/bin:$PATH" VSW_WG_LOCAL="$T/srv" VSW_TTY="$T/tty" VSW_LOG_DIR="$T/log" VSW_LOCK_DIR="$T/lock"
G=src/shell/net/wireguard.sh
: > "$T/tty"

fresh
bash "$G" setup --host db --peer web --dry-run > "$T/o" 2>&1
grep -q 'db  region ams3  endpoint 203.0.113.10  tunnel 10.200.0.1' "$T/o" && grep -q 'web  region nyc1  endpoint 198.51.100.20' "$T/o" \
  && grep -q 'dry run: nothing changed' "$T/o" && [ ! -e "$T/srv/db/etc" ] && ! grep -qE 'genkey|allow|restart' "$T/calls" \
  && ok "setup --dry-run: plan with detected endpoints and regions, nothing written" || { cat "$T/o"; fail "dry run"; }
if bash "$G" setup --host db --peer web >"$T/o" 2>&1; then fail "setup without yes"; fi
[ ! -e "$T/srv/db/etc/wireguard/wg0.key" ] && ok "setup: not confirmed without --yes, no keys made" || fail "confirm"

bash "$G" setup --host db --peer web --yes > "$T/o" 2>&1 || { cat "$T/o"; fail "setup --yes"; }
dc="$T/srv/db/etc/wireguard/wg0.conf" wc="$T/srv/web/etc/wireguard/wg0.conf"
perm() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
[ "$(perm "$dc")" = 600 ] && [ "$(perm "$T/srv/db/etc/wireguard/wg0.key")" = 600 ] && [ "$(perm "$wc")" = 600 ] \
  && ok "setup: configs and keys are 600" || fail "modes"
! grep -rq 'SECRET' "$dc" "$wc" "$T/o" "$T/log" && grep -q 'PostUp = wg set %i private-key /etc/wireguard/wg0.key' "$dc" \
  && ok "private keys are never printed, logged or written into wg0.conf" || fail "private key leaked"
wpub="$(wg pubkey < "$T/srv/web/etc/wireguard/wg0.key")"; dpub="$(wg pubkey < "$T/srv/db/etc/wireguard/wg0.key")"
grep -q "PublicKey = $wpub" "$dc" && grep -q "PublicKey = $dpub" "$wc" && grep -q 'Endpoint = 198.51.100.20:51820' "$dc" \
  && grep -q 'Endpoint = 203.0.113.10:51820' "$wc" && grep -q 'AllowedIPs = 10.200.0.2/32' "$dc" && grep -q 'Address = 10.200.0.2/24' "$wc" \
  && ! grep -q "$wpub" "$T/o" && ok "public keys exchanged (shown as fingerprints only); peers point at each other" || { cat "$dc" "$wc"; fail "peers"; }
grep -q 'allow proto udp from 198.51.100.20 to any port 51820' "$T/srv/db/ufw" && grep -q 'allow in on wg0 proto tcp from 10.200.0.2 to any port 6432' "$T/srv/db/ufw" \
  && grep -q 'allow proto udp from 203.0.113.10 to any port 51820' "$T/srv/web/ufw" && ! grep -q 'tcp' "$T/srv/web/ufw" \
  && ok "ufw: WireGuard port from the peer only; DB ports on wg0 from the peer tunnel IP only (DB side)" || fail "ufw"
[ -f "$T/srv/db/etc/systemd/system/docker.service.d/10-vsw-wireguard.conf" ] && [ ! -e "$T/srv/web/etc/systemd/system/docker.service.d" ] \
  && grep -q 'systemctl restart wg-quick@wg0 \[db\]' "$T/calls" && grep -q 'last handshake' "$T/o" && grep -q 'EXTRA_BIND_IPS=10.200.0.1  PEER_REGIONS=nyc1' "$T/o" \
  && ok "DB side: docker after the tunnel; tunnel up, handshake checked, next steps printed" || { cat "$T/o"; fail "after"; }
k1="$(cat "$T/srv/db/etc/wireguard/wg0.key")"; bash "$G" setup --host db --peer web --yes >/dev/null 2>&1
[ "$(cat "$T/srv/db/etc/wireguard/wg0.key")" = "$k1" ] && [ "$(grep -c 51820 "$T/srv/db/ufw")" = 1 ] && ok "re-run keeps the keys and adds no duplicate ufw rules" || fail "idempotent"

fresh; mkdir -p "$T/srv/web/home/ploi"
bash "$G" setup --host db --peer web --yes > "$T/o" 2>&1
[ ! -f "$T/srv/web/ufw" ] && grep -q 'Ploi -> Server -> Network: UDP 51820 from 203.0.113.10' "$T/o" && ok "Ploi peer: rule printed for the Ploi panel, ufw untouched" || { cat "$T/o"; fail "ploi"; }

bash "$G" setup --host db --peer db >/dev/null 2>&1 && fail "same host" || ok "setup refuses --host = --peer"
bash "$G" setup --host db --peer web --host-ip 10.200.0.1 --peer-ip 10.201.0.2 >/dev/null 2>&1 && fail "/24" || ok "tunnel IPs must share a /24"
bash "$G" apply --self-ip 10.200.0.1 --peer-ip 10.200.0.2 --peer-endpoint 192.0.2.1 --peer-pubkey 'not-a-key' >/dev/null 2>&1 && fail "bad key" || ok "apply rejects a malformed public key"
bash "$G" setup --host db --peer web --port 99999 >/dev/null 2>&1 && fail "port" || ok "validates --port"
VSW_SYSROOT="$T/srv/db" bash "$G" remove --yes >/dev/null 2>&1; [ ! -f "$T/srv/db/etc/wireguard/wg0.conf" ] && ls "$T/srv/db/etc/wireguard/"wg0.conf.bak.* >/dev/null 2>&1 \
  && ok "remove: disabled, config backed up" || fail "remove"
echo "smoke-net: $pass passed, 0 failed"
