#!/usr/bin/env bash
# wg-it: a real two-host WireGuard tunnel between two throwaway "servers" (Ubuntu containers with sshd),
# driven from this workstation by `wireguard.sh setup` over real ssh, exactly like production.
#
# Why containers work: WireGuard lives in the kernel, and a container with CAP_NET_ADMIN can create a wg
# interface in its own network namespace when the Docker VM's kernel has the module (OrbStack, Docker
# Desktop >= 4.x on recent kernels, GitHub's ubuntu runners). No --privileged, no host changes.
# Skip detection: if `ip link add type wireguard` fails in a probe container the suite prints SKIP and
# exits 0 (WG_IT_REQUIRE=1 turns that into a failure, for CI on runners known to have the module).
# No systemd in a container: a systemctl stub maps wg-quick@IFACE to wg-quick up/down (tests/shell/wg/).
# The ssh key is generated for this run in a temp dir and deleted with it; no key is ever printed.
# shellcheck disable=SC2015  # guard idiom
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "wg-it skipped (no docker)"; exit 0; }
IMG=vsw-test/wg-it:1 NET=vsw_wgit SUB=172.30.98 P=wgit DB_SSH=22922 WEB_SSH=22923
W="$(mktemp -d /tmp/vsw-wgit.XXXX)"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { rm -rf /tmp/vsw-wg-last; mkdir -p /tmp/vsw-wg-last; cp "$W"/*.out /tmp/vsw-wg-last/ 2>/dev/null || true
  docker rm -f "$P-db" "$P-web" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

docker build -q -t "$IMG" tests/shell/wg >/dev/null || fail "build $IMG"
if ! docker run --rm --cap-add NET_ADMIN "$IMG" ip link add wgprobe type wireguard >/dev/null 2>&1; then
  msg="wg-it SKIP: this Docker kernel has no WireGuard module (ip link add type wireguard failed)"
  [ "${WG_IT_REQUIRE:-0}" = 1 ] && fail "$msg"; echo "$msg"; exit 0
fi
ok "probe: the Docker kernel creates wireguard interfaces (CAP_NET_ADMIN, no --privileged)"

docker network inspect "$NET" >/dev/null 2>&1 && fail "network $NET exists; remove it first"
docker network create --subnet "$SUB.0/24" "$NET" >/dev/null
for n in db:10:$DB_SSH web:20:$WEB_SSH; do IFS=: read -r h ip port <<<"$n"
  docker run -d --name "$P-$h" --hostname "$P-$h" --network "$NET" --ip "$SUB.$ip" --cap-add NET_ADMIN \
    -p "127.0.0.1:$port:22" "$IMG" >/dev/null
done
ssh-keygen -q -t ed25519 -N '' -C wg-it -f "$W/id" >/dev/null
for h in db web; do docker cp "$W/id.pub" "$P-$h:/root/.ssh/authorized_keys" >/dev/null
  docker exec "$P-$h" sh -c 'chown root:root /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys'; done
cat > "$W/ssh_config" <<CFG
Host wgdb wgweb
  HostName 127.0.0.1
  User root
  IdentityFile $W/id
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile $W/known_hosts
  LogLevel ERROR
Host wgdb
  Port $DB_SSH
Host wgweb
  Port $WEB_SSH
CFG
mkdir -p "$W/bin"
for c in ssh scp; do printf '#!/bin/sh\nexec %s -F "%s/ssh_config" "$@"\n' "$(command -v $c)" "$W" > "$W/bin/$c"; chmod 755 "$W/bin/$c"; done
export PATH="$W/bin:$PATH"
for _ in $(seq 1 20); do ssh -o ConnectTimeout=2 wgdb true 2>/dev/null && ssh -o ConnectTimeout=2 wgweb true 2>/dev/null && break; sleep 1; done
ssh wgdb true && ssh wgweb true && ok "two servers reachable over real ssh (test key, never printed)" || fail "ssh"

# ufw on, like a hardened server (ssh allowed); it filters inside each container's namespace only
for h in db web; do docker exec "$P-$h" sh -c 'ufw allow 22/tcp >/dev/null && ufw --force enable >/dev/null' || fail "ufw on $h"; done
ok "ufw active on both servers"

WG=src/shell/net/wireguard.sh
bash $WG setup --host wgdb --peer wgweb --dry-run > "$W/plan.out" 2>&1 || { cat "$W/plan.out"; fail "dry run"; }
grep -q "endpoint $SUB.10" "$W/plan.out" && grep -q "endpoint $SUB.20" "$W/plan.out" && grep -q 'dry run: nothing changed' "$W/plan.out" \
  && ! docker exec "$P-db" test -e /etc/wireguard/wg0.conf && ok "setup --dry-run: endpoints detected, nothing written" || { cat "$W/plan.out"; fail "plan"; }

bash $WG setup --host wgdb --peer wgweb --yes > "$W/setup.out" 2>&1 || { cat "$W/setup.out"; fail "setup"; }
grep -q 'ping 10.200.0.1 through the tunnel' "$W/setup.out" && grep -q 'last handshake' "$W/setup.out" \
  && ok "setup --yes: tunnel up, handshake, ping web -> db through wg0" || { cat "$W/setup.out"; fail "tunnel"; }
docker exec "$P-db" ping -c 2 -W 2 10.200.0.2 >/dev/null && ok "ping db -> web through the tunnel" || fail "ping back"

leak=0; for h in db web; do k="$(docker exec "$P-$h" cat /etc/wireguard/wg0.key)"; grep -qF "$k" "$W/plan.out" "$W/setup.out" && leak=1
  docker exec "$P-$h" grep -rqF "$k" /etc/wireguard/wg0.conf /var/log/vps-server-workbench 2>/dev/null && leak=1; done; k=""
[ "$leak" = 0 ] && ok "private keys never printed, not in wg0.conf, not in the audit log" || fail "private key leaked"
for h in db web; do [ "$(docker exec "$P-$h" stat -c %a /etc/wireguard/wg0.key /etc/wireguard/wg0.conf | tr '\n' ' ')" = "600 600 " ] || fail "$h modes"; done
ok "wg0.key and wg0.conf are 600 on both servers"

docker exec "$P-db" ufw status > "$W/ufw-db.out"
grep -qE "^51820/udp +ALLOW( IN)? +$SUB\.20( |$)" "$W/ufw-db.out" && grep -qE '^6432/tcp on wg0 +ALLOW( IN)? +10\.200\.0\.2( |$)' "$W/ufw-db.out" \
  && ok "ufw on db: UDP 51820 from the web endpoint only, 6432 on wg0 from the web tunnel IP only" || { cat "$W/ufw-db.out"; fail "ufw rules"; }
# a "DB" listening on all interfaces: reachable through the tunnel, blocked on the plain network by ufw
docker exec -d "$P-db" sh -c 'while true; do nc -l -p 6432 -q 0 </dev/null >/dev/null 2>&1; done'
sleep 1
docker exec "$P-web" nc -z -w 3 10.200.0.1 6432 && ok "web reaches db:6432 through the tunnel" || fail "6432 via tunnel"
docker exec "$P-web" nc -z -w 3 "$SUB.10" 6432 && fail "db:6432 reachable outside the tunnel" || ok "db:6432 not reachable outside the tunnel (ufw)"

h1="$(docker exec "$P-db" wg show wg0 public-key)"
bash $WG setup --host wgdb --peer wgweb --yes > "$W/setup2.out" 2>&1 || { cat "$W/setup2.out"; fail "re-setup"; }
[ "$(docker exec "$P-db" wg show wg0 public-key)" = "$h1" ] && [ "$(docker exec "$P-db" ufw status | grep -c 'vsw wireguard')" -le 2 ] \
  && grep -q 'last handshake' "$W/setup2.out" && ok "re-run setup: same keys, no duplicate ufw rules, tunnel back up" || { cat "$W/setup2.out"; fail "idempotent"; }

bash $WG status --host wgweb --ping 10.200.0.1 > "$W/status.out" 2>&1 && grep -q 'ping 10.200.0.1 through the tunnel' "$W/status.out" \
  && ! grep -qiE 'private' "$W/status.out" && ok "status --host: handshake + ping, no key material" || { cat "$W/status.out"; fail "status"; }

bash $WG remove --host wgweb --dry-run > "$W/rm0.out" 2>&1 && docker exec "$P-web" ip link show wg0 >/dev/null 2>&1 && ok "remove --dry-run changes nothing" || fail "remove dry"
bash $WG remove --host wgweb --yes > "$W/rm.out" 2>&1 || { cat "$W/rm.out"; fail "remove"; }
! docker exec "$P-web" ip link show wg0 >/dev/null 2>&1 && ! docker exec "$P-web" test -e /etc/wireguard/wg0.conf \
  && docker exec "$P-web" sh -c 'ls /etc/wireguard/wg0.conf.bak* >/dev/null 2>&1 && test -s /etc/wireguard/wg0.key' \
  && ok "remove: interface down, config backed up, key kept" || { cat "$W/rm.out"; docker exec "$P-web" ls -la /etc/wireguard; fail "removed state"; }
docker exec "$P-db" grep -q 'tool=wireguard .*apply' /var/log/vps-server-workbench/audit.log && ok "audit log on the servers records keygen/apply" || fail "audit"
echo "wg-it: all $pass checks passed"
