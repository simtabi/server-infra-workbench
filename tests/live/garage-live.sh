#!/usr/bin/env bash
# Live test: a three-node Garage cluster on three real droplets talking over their own VPC
# (make live-test). The repeatable version of what garage-cluster-it fakes on one Docker host:
#   * Docker installed by init.sh --host (swap + docker items) on each node, in parallel
#   * addon.sh on each node (copied with the stacks it needs): host networking bound to the VPC
#     address, GARAGE_REPLICATION=3, one zone per node, joins with GARAGE_PEERS and a copied secrets.env
#   * S3 and RPC listen on the VPC address only, the admin API on loopback; the public address does not answer
#   * an object written through node 1 is read back through node 3 over the VPC
#   * node 2 stopped: reads and writes still work (quorum 2 of 3), doctor warns but passes;
#     node 2 back: it serves what was written while it was down
#   * no cluster secret in any output
# WHY: the cluster's whole point is surviving the loss of a droplet; only separate machines on a
# real private network prove the bind addresses, the RPC mesh and the quorum.
# Dry run by default; --yes spends (three s-1vcpu-1gb for under an hour, about $0.03). See docs/live-tests.md.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/live/lib/live.sh
. tests/live/lib/live.sh
LIVE_TIMEOUT_MIN=45 LIVE_MAX_USD=0.50
live_args "$@"
live_begin garage 3
out() { echo "$LIVE_W/$1.out"; }
NODES="n1 n2 n3"
A=/opt/siw/src/shell/addons/addon.sh
node() { local n="$1"; shift; live_ssh "$n" "ADDON_CONF=/etc/vsw-addons.conf $A $*"; }
gx() { live_ssh "$1" "docker exec -e RUST_LOG=warn \$(docker ps -q --filter label=com.docker.compose.service=garage | head -1) /garage ${*:2}"; }

live_vpc_create; live_sshkey_create; live_firewall_create
live_droplets_create n1 n2 n3

# ---- 1. Docker on every node (init.sh --host, in parallel) -----------------------------------
pids=""; for n in $NODES; do
  src/shell/server/init.sh --host "$n" --role db --only swap,docker --yes > "$(out "init-$n")" 2>&1 </dev/null & pids="$pids $!"
done
rc=0; for p in $pids; do wait "$p" || rc=1; done
[ "$rc" = 0 ] && live_ok "init.sh --host --only swap,docker on 3 nodes in parallel" || { for n in $NODES; do tail -15 "$(out "init-$n")"; done; live_fail "init"; }

# ---- 2. the add-on tool + its stacks on every node; a conf per node -------------------------
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$LIVE_W/siw.tgz" src/shell/addons src/shell/lib stacks/addons
for n in $NODES; do
  ip="$(live_private_ip "$n")"; z="dc${n#n}"
  scp -q "$LIVE_W/siw.tgz" "$n:/root/siw.tgz"
  live_ssh "$n" "mkdir -p /opt/siw && tar -C /opt/siw -xzf /root/siw.tgz && rm -f /root/siw.tgz
    umask 077; printf 'ADDON_BIND=%s\nADDON_NETWORK=host\nGARAGE_ZONE=%s\nGARAGE_CAPACITY=1G\nGARAGE_REPLICATION=3\nSTORAGE_BUCKET=cluster\n' '$ip' '$z' > /etc/vsw-addons.conf"
done
live_ok "addon.sh + stacks/addons copied; ADDON_BIND = each node's VPC address, one zone per node"

# ---- 3. the cluster ------------------------------------------------------------------------------
node n1 install garage --role db --yes > "$(out n1)" 2>&1 && grep -q 'layout staged' "$(out n1)" && live_ok "n1: installed, layout staged (1 of 3)" || { tail -30 "$(out n1)"; live_fail "n1 install"; }
id1="$(node n1 garage-node-id)"; ip1="$(live_private_ip n1)"
[[ "$id1" =~ ^[0-9a-f]{64}@${ip1//./\\.}:3901$ ]] && live_ok "n1 node id is <id>@<VPC address>:3901" || live_fail "garage-node-id: $id1"
live_ssh n2 "printf 'GARAGE_PEERS=%s\n' '$id1' >> /etc/vsw-addons.conf"
if node n2 install garage --role db --yes > "$(out n2a)" 2>&1; then live_fail "n2 joined without the cluster secrets"; fi
grep -q 'copy secrets.env' "$(out n2a)" && live_ok "n2: joining without the cluster's secrets.env is refused" || { cat "$(out n2a)"; live_fail "join gate"; }
for n in n2 n3; do   # secrets.env: node to node through this machine's pipe, never printed or stored here
  live_ssh n1 'cat /opt/siw-addons/garage/secrets.env' | live_ssh "$n" 'umask 077; mkdir -p /opt/siw-addons/garage && cat > /opt/siw-addons/garage/secrets.env'
done
node n2 install garage --role db --yes > "$(out n2)" 2>&1 && grep -q 'layout staged' "$(out n2)" && live_ok "n2: joined n1 over the VPC (2 of 3)" || { tail -30 "$(out n2)"; live_fail "n2 install"; }
id2="$(node n2 garage-node-id)"
live_ssh n3 "printf 'GARAGE_PEERS=%s,%s\n' '$id1' '$id2' >> /etc/vsw-addons.conf"
node n3 install garage --role db --yes > "$(out n3)" 2>&1 && grep -q 'garage: layout apply version 1' "$(out n3)" && grep -q 'garage: bucket cluster' "$(out n3)" \
  && live_ok "n3: third zone applies layout v1, creates the bucket and app key" || { tail -30 "$(out n3)"; live_fail "n3 install"; }
gx n1 layout show > "$(out layout)" 2>&1 || true
[ "$(sed '/STAGED/,$d' "$(out layout)" | grep -cE '^[0-9a-f]{16} .* dc[123] ')" = 3 ] && live_ok "layout: 3 nodes in 3 zones" || { cat "$(out layout)"; live_fail "layout"; }

# ---- 4. exposure: VPC address only -----------------------------------------------------------------
for n in $NODES; do
  ip="$(live_private_ip "$n")"
  live_ssh "$n" "ss -Htln | awk '{print \$4}' | grep -E ':(3900|3901|3903)\$'" > "$LIVE_W/listen-$n.txt" || true
  # S3 + RPC on the VPC address, the admin API on loopback only, nothing else
  sort -u "$LIVE_W/listen-$n.txt" > "$LIVE_W/listen-$n.got"; printf '%s\n' "$ip:3900" "$ip:3901" "127.0.0.1:3903" | sort > "$LIVE_W/listen-$n.want"
  cmp -s "$LIVE_W/listen-$n.got" "$LIVE_W/listen-$n.want" || { sed -E 's/^10\.[0-9.]+:/<vpc>:/' "$LIVE_W/listen-$n.got"; live_fail "$n listens beyond VPC:3900/3901 + 127.0.0.1:3903"; }
done
live_ok "S3 + RPC on each node's VPC address only, admin API on loopback"
pub1="$(awk '/^Host n1$/{f=1} f && $1=="HostName"{print $2; exit}' "$LIVE_W/ssh_config")"
! curl -s --max-time 5 -o /dev/null "http://$pub1:3900/" && live_ok "n1's public address does not answer on 3900 (from this machine)" || live_fail "S3 reachable on the public address"

# ---- 5. data across nodes, a node down --------------------------------------------------------------
node n1 laravel-env garage --out /root/app.env > "$(out env)" 2>&1 || live_fail "laravel-env"
# S3 calls run on n1 against any node's VPC address (curl >= 7.75 signs SigV4)
s3() { local m="$1" ip; ip="$(live_private_ip "$2")"; shift 2
  live_ssh n1 ". /root/app.env; printf 'user = \"%s:%s\"\naws-sigv4 = \"aws:amz:%s:s3\"\n' \"\$AWS_ACCESS_KEY_ID\" \"\$AWS_SECRET_ACCESS_KEY\" \"\$AWS_DEFAULT_REGION\" \
    | curl -s -o /root/s3.body -w '%{http_code}' -K - -X $m http://$ip:3900/cluster/$*"; }
live_ssh n1 'head -c 65536 /dev/urandom > /root/obj.bin'
[ "$(s3 PUT n1 "obj.bin --data-binary @/root/obj.bin")" = 200 ] && [ "$(s3 GET n3 obj.bin)" = 200 ] && live_ssh n1 'cmp -s /root/obj.bin /root/s3.body' \
  && live_ok "write through n1, read the same bytes through n3 (over the VPC)" || live_fail "cross-node read"
live_ssh n2 'docker stop $(docker ps -q --filter label=com.docker.compose.service=garage) >/dev/null'
[ "$(s3 GET n1 obj.bin)" = 200 ] && [ "$(s3 PUT n3 "b.bin --data-binary @/root/obj.bin")" = 200 ] \
  && live_ok "n2 down: reads and writes still succeed (quorum 2 of 3)" || live_fail "one node down"
for _ in $(seq 1 30); do [ "$(gx n1 status 2>/dev/null | sed -n '/HEALTHY NODES/,/^$/p' | grep -cE '^[0-9a-f]{16} ' || true)" -le 2 ] && break; sleep 2; done
node n1 doctor garage > "$(out doc2)" 2>&1 || true
grep -qE 'warn +healthy nodes: 2 of 3' "$(out doc2)" && ! grep -qE '(BAD|FAIL).*healthy nodes' "$(out doc2)" \
  && live_ok "doctor with n2 down: a warning (quorum kept), not a failure" || { cat "$(out doc2)"; live_fail "doctor 2 of 3"; }
live_ssh n2 'docker start $(docker ps -aq --filter label=com.docker.compose.service=garage) >/dev/null'
code=000; for _ in $(seq 1 30); do code="$(s3 GET n2 b.bin || true)"; [ "$code" = 200 ] && break; sleep 2; done
[ "$code" = 200 ] && live_ssh n1 'cmp -s /root/obj.bin /root/s3.body' && live_ok "n2 back: serves the object written while it was down" || live_fail "n2 catch-up (HTTP $code)"
for _ in $(seq 1 30); do [ "$(gx n1 status 2>/dev/null | sed -n '/HEALTHY NODES/,/^$/p' | grep -cE '^[0-9a-f]{16} ' || true)" -ge 3 ] && break; sleep 2; done
node n1 doctor garage > "$(out doc)" 2>&1 && grep -q 'healthy nodes: 3 (replication 3)' "$(out doc)" \
  && live_ok "doctor on n1: 3 healthy nodes" || { cat "$(out doc)"; live_fail "doctor"; }

# ---- 6. no secret in any output -----------------------------------------------------------------------
live_ssh n1 "sed -n 's/^[A-Z_]*=//p' /opt/siw-addons/garage/secrets.env /root/app.env" > "$LIVE_W/secrets.txt"; chmod 600 "$LIVE_W/secrets.txt"
leak=0; while IFS= read -r v; do [ "${#v}" -ge 12 ] || continue; cat "$LIVE_W"/*.out | grep -qF -- "$v" && leak=1; done < "$LIVE_W/secrets.txt"
rm -f "$LIVE_W/secrets.txt"
[ "$leak" = 0 ] && live_ok "no cluster secret in any output" || live_fail "secret printed"
echo "garage-live: $LIVE_PASS checks passed"
