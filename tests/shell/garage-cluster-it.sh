#!/usr/bin/env bash
# Integration test: a three-node Garage cluster built only with addon.sh, in host networking mode.
# Each "node" is its own ADDONS_DIR + compose project + port set on the Docker host's network namespace,
# so this exercises: ADDON_NETWORK=host binding, GARAGE_REPLICATION=3, GARAGE_PEERS joins with a copied
# secrets.env, staged layout applied by the third install, replication across nodes, a node down.
# Not in `make ci` (Docker, ~2 min): run by `make it`. Names and ports follow VSW_IT_PREFIX (tests/shell/it-lib.sh).
# shellcheck disable=SC2015
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "garage-cluster-it skipped (no docker)"; exit 0; }
A="$PWD/src/shell/addons/addon.sh"
W="$(mktemp -d /tmp/vsw-gcl.XXXX)"; P="$(it_name -gcl)"; LAST="/tmp/$P-last"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() {
  it_purge "$P-n1" "$P-n2" "$P-n3"
  rm -rf "$LAST"; mkdir -p "$LAST"; cp "$W"/*.out "$LAST/" 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
s3p() { it_port "249${1}0"; }; rpcp() { it_port "249${1}1"; }; admp() { it_port "249${1}3"; }
for i in 1 2 3; do
  cat > "$W/n$i.conf" <<CONF
ADDONS_DIR=$W/n$i
AUDIT_LOG=$W/audit-n$i.log
ADDON_BIND=127.0.0.1
ADDON_NETWORK=host
GARAGE_S3_PORT=$(s3p "$i")
GARAGE_RPC_PORT=$(rpcp "$i")
GARAGE_ADMIN_PORT=$(admp "$i")
GARAGE_ZONE=dc$i
GARAGE_CAPACITY=1G
GARAGE_REPLICATION=3
STORAGE_BUCKET=cluster
ADDON_DISK_WARN_PCT=100
ADDON_DISK_BAD_PCT=100
CONF
done
# node N: its own conf and compose project (the template's `name:` is overridden by COMPOSE_PROJECT_NAME)
node() { local i="$1"; shift; ADDON_CONF="$W/n$i.conf" ADDON_ALLOW_NONROOT=1 COMPOSE_PROJECT_NAME="$P-n$i" "$A" "$@"; }
gx() { local i="$1"; shift; docker exec -e RUST_LOG=warn "$(docker ps -q --filter "label=com.docker.compose.project=$P-n$i" | head -1)" /garage "$@"; }
# S3 from the Docker host's network namespace (host networking binds there, not on a Docker Desktop VM's client)
s3() { local f="$1" m="$2" u="$3"; shift 3
  printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:%s:s3"\n' "$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$f")" \
    "$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' "$f")" "$(sed -n 's/^AWS_DEFAULT_REGION=//p' "$f")" \
    | docker run --rm -i --network host -v "$W:/w" "$CURL_IMAGE" -s -o /w/s3.body -w '%{http_code}' -K - -X "$m" "$u" "$@"; }
CURL_IMAGE="curlimages/curl:8.17.0"
docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 || docker pull -q "$CURL_IMAGE" >/dev/null
openssl rand -hex 64 > "$W/obj.bin"

node 1 install garage --role web --yes > "$W/n1.out" 2>&1 && grep -q 'layout staged' "$W/n1.out" && ! grep -q 'garage: bucket' "$W/n1.out" \
  && ok "node 1: installed in host mode; layout staged (1 of 3), no bucket yet" || { it_why "$W/n1.out" 30; fail "node 1 install"; }
c1="$(docker ps -q --filter "label=com.docker.compose.project=$P-n1")"
[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c1")" = host ] && [ -z "$(docker port "$c1")" ] \
  && ok "host networking: no published ports" || fail "network mode"
docker run --rm --network host busybox:1.37 netstat -ltn > "$W/listen.out" 2>&1
ports1="($(s3p 1)|$(rpcp 1)|$(admp 1))"
grep -E ":$ports1 " "$W/listen.out" | awk '{print $4}' | grep -qv '^127\.0\.0\.1:' && fail "garage listens beyond 127.0.0.1" || true
[ "$(grep -cE "127\.0\.0\.1:$ports1 " "$W/listen.out")" = 3 ] && ok "S3, RPC and admin listen on 127.0.0.1 only" || { cat "$W/listen.out"; fail "listen addresses"; }
id1="$(node 1 garage-node-id 2>"$W/id.err")"
[[ "$id1" =~ ^[0-9a-f]{64}@127\.0\.0\.1:$(rpcp 1)$ ]] && ok "garage-node-id: <id>@<ADDON_BIND>:<rpc port>" || fail "garage-node-id: $id1"

printf 'GARAGE_PEERS=%s\n' "$id1" >> "$W/n2.conf"
if node 2 install garage --role web --yes > "$W/n2a.out" 2>&1; then fail "node 2 joined without the cluster secrets"; fi
grep -q 'copy secrets.env' "$W/n2a.out" && [ ! -e "$W/n2/garage/docker-compose.yml" ] && ok "joining without the cluster's secrets.env is refused before anything is written" || { cat "$W/n2a.out"; fail "join gate"; }
mkdir -p "$W/n2/garage" "$W/n3/garage"; chmod 700 "$W/n2" "$W/n3"
(umask 077; cp "$W/n1/garage/secrets.env" "$W/n2/garage/secrets.env"; cp "$W/n1/garage/secrets.env" "$W/n3/garage/secrets.env")
node 2 install garage --role web --yes > "$W/n2.out" 2>&1 && grep -q 'layout staged' "$W/n2.out" && ok "node 2: joined node 1; layout staged (2 of 3)" || { it_why "$W/n2.out" 30; fail "node 2 install"; }
id2="$(node 2 garage-node-id)"
printf 'GARAGE_PEERS=%s,%s\n' "$id1" "$id2" >> "$W/n3.conf"
node 3 install garage --role web --yes > "$W/n3.out" 2>&1 && grep -q 'garage: layout apply version 1' "$W/n3.out" && grep -q 'garage: bucket cluster' "$W/n3.out" \
  && grep -q 'garage: app key' "$W/n3.out" && ok "node 3: third zone applies layout v1, creates the bucket and app key" || { it_why "$W/n3.out" 30; fail "node 3 install"; }
gx 1 layout show > "$W/layout.out" 2>&1
[ "$(sed '/STAGED/,$d' "$W/layout.out" | grep -cE '^[0-9a-f]{16} .* dc[123] ')" = 3 ] && grep -q 'Zone redundancy: maximum' "$W/layout.out" \
  && ok "layout: 3 nodes in 3 zones, maximum zone redundancy" || { cat "$W/layout.out"; fail "layout"; }
for i in 1 2 3; do grep -qx 'replication_factor = 3' "$W/n$i/garage/garage.toml" || fail "n$i replication"; done
[ "$(mode "$W/n2/garage/secrets.env")" = 600 ] && [ "$(mode "$W/n3/garage/garage.toml")" = 600 ] && ok "replication_factor = 3 on every node; secrets and toml 600" || fail "modes"

node 1 laravel-env garage --out "$W/app.env" > "$W/env.out" 2>&1
[ "$(s3 "$W/app.env" PUT "http://127.0.0.1:$(s3p 1)/cluster/obj.bin" --data-binary @/w/obj.bin)" = 200 ] \
  && [ "$(s3 "$W/app.env" GET "http://127.0.0.1:$(s3p 3)/cluster/obj.bin")" = 200 ] && cmp -s "$W/s3.body" "$W/obj.bin" \
  && ok "write through node 1, read the same bytes through node 3" || fail "cross-node read"
docker stop "$(docker ps -q --filter "label=com.docker.compose.project=$P-n2")" >/dev/null
[ "$(s3 "$W/app.env" GET "http://127.0.0.1:$(s3p 1)/cluster/obj.bin")" = 200 ] && cmp -s "$W/s3.body" "$W/obj.bin" \
  && [ "$(s3 "$W/app.env" PUT "http://127.0.0.1:$(s3p 3)/cluster/b.bin" --data-binary @/w/obj.bin)" = 200 ] \
  && ok "node 2 down: reads and writes still succeed (quorum 2 of 3)" || fail "one node down"
docker start "$(docker ps -aq --filter "label=com.docker.compose.project=$P-n2")" >/dev/null
code=000; for _ in $(seq 1 30); do code="$(s3 "$W/app.env" GET "http://127.0.0.1:$(s3p 2)/cluster/b.bin" || true)"; [ "$code" = 200 ] && break; sleep 2; done
[ "$code" = 200 ] && cmp -s "$W/s3.body" "$W/obj.bin" \
  && ok "node 2 back: serves the object written while it was down" || { gx 1 status; fail "node 2 catch-up (HTTP $code)"; }
# node 2 can serve before node 1 has re-marked it healthy; doctor reads node 1's view, so wait for it
for _ in $(seq 1 30); do [ "$(gx 1 status 2>/dev/null | sed -n '/HEALTHY NODES/,/^$/p' | grep -cE '^[0-9a-f]{16} ' || true)" -ge 3 ] && break; sleep 2; done
node 1 doctor garage > "$W/doc.out" 2>&1 && grep -q 'healthy nodes: 3 (replication 3)' "$W/doc.out" && grep -q 'layout applied' "$W/doc.out" \
  && ok "doctor on node 1: layout applied, 3 healthy nodes" || { cat "$W/doc.out"; gx 1 status; fail "doctor"; }
node 3 install garage --role web --yes > "$W/n3b.out" 2>&1 && ! grep -qE 'garage: (layout|bucket|app key)' "$W/n3b.out" \
  && ok "re-install on node 3 is idempotent" || { it_why "$W/n3b.out" 20; fail "idempotent"; }
sed -i.bak 's/^GARAGE_REPLICATION=3/GARAGE_REPLICATION=1/' "$W/n1.conf"
if node 1 plan garage > "$W/rf.out" 2>&1; then fail "replication change accepted"; fi
grep -q 'cannot change it in place' "$W/rf.out" && ok "changing replication on an installed node is refused" || { cat "$W/rf.out"; fail "rf gate"; }

leak=0; while IFS='=' read -r k v; do case "$k" in ""|\#*) continue ;; esac; [ "${#v}" -ge 8 ] || continue
  cat "$W"/*.out "$W"/audit-n*.log 2>/dev/null | grep -qF -- "$v" && { echo "leak: $k"; leak=1; }; done < "$W/n1/garage/secrets.env"
[ "$leak" = 0 ] && ok "no cluster secret in any output or audit log" || fail "secret leak"
echo "garage-cluster-it: $pass checks passed"
