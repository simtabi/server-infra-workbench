#!/usr/bin/env bash
# smoke-addons.sh - offline checks for src/shell/addons/addon.sh and stacks/addons (no Docker, no servers).
# shellcheck disable=SC2016  # single-quoted snippets run in a child shell on purpose
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
A="$ROOT/src/shell/addons/addon.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0 fail=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
no() { echo "FAIL $*"; [ -s "$W/last.err" ] && sed "s/^/     /" "$W/last.err" | tail -3; fail=$((fail + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>"$W/last.err"; then ok "$d"; else no "$d"; fi; }
refuses() { local d="$1" pat="$2"; shift 2; local out; rm -f "$W/last.err"; if out="$("$@" 2>&1)"; then no "$d (exit 0)"; elif grep -q -- "$pat" <<<"$out"; then ok "$d"; else no "$d: $out"; fi; }
cat > "$W/addons.conf" <<CONF
ADDONS_DIR=$W/root
AUDIT_LOG=$W/audit.log
CONF
export ADDON_CONF="$W/addons.conf" ADDON_ALLOW_NONROOT=1
unset ADDON_BIND ADDON_ENV ACCEPT_EXPERIMENTAL RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY

check "bash -n addon.sh" bash -n "$A"
check "list shows four add-ons" bash -c "'$A' list | grep -cE '^(gotenberg|garage|seaweedfs|rustfs) ' | grep -qx 4"
check "plan gotenberg (web role) binds 127.0.0.1" bash -c "'$A' plan gotenberg | grep -q 'listens  127.0.0.1:3000'"
check "plan writes nothing" test ! -e "$W/root/gotenberg"
check "plan never prints a secret value" bash -c "! '$A' plan garage --bind 10.10.0.5 | grep -qiE '[0-9a-f]{32}'"
check "gotenberg on a private IP turns basic auth on" bash -c "'$A' plan gotenberg --role dedicated --bind 10.10.0.5 | grep -q 'basic auth on'"
refuses "refuses 0.0.0.0" "refusing to bind 0.0.0.0" "$A" plan gotenberg --bind 0.0.0.0
refuses "refuses a public IP" "not a private" "$A" plan garage --bind 203.0.113.7
refuses "unknown add-on exits 2" "unknown add-on" "$A" plan minio
check "unknown add-on exit code is 2" bash -c "'$A' plan minio; [ \$? -eq 2 ]"
refuses "bad role" "--role must be" "$A" plan garage --role cache --bind 10.10.0.5
refuses "rustfs needs --accept-experimental" "EXPERIMENTAL" "$A" plan rustfs --bind 10.10.0.5
refuses "rustfs refused on prd" "protected env" env ADDON_ENV=prd "$A" plan rustfs --bind 10.10.0.5 --accept-experimental
refuses "rustfs refuses rustfsadmin" "default credentials" env RUSTFS_ACCESS_KEY=rustfsadmin "$A" plan rustfs --bind 10.10.0.5 --accept-experimental
refuses "rustfs refuses minioadmin" "default credentials" env RUSTFS_SECRET_KEY=minioadmin "$A" plan rustfs --bind 10.10.0.5 --accept-experimental  # vsw-secrets: ignore (public vendor default; proves it is refused)
check "rustfs plan ok with the gate passed" "$A" plan rustfs --bind 10.10.0.5 --accept-experimental
mkdir -p "$W/root/garage" && echo "ADDON_NAME=garage" > "$W/root/garage/stack.env"
refuses "one object store per node" "already installed" "$A" plan seaweedfs --bind 10.10.0.5
rm -rf "$W/root/garage"
# multi-node Garage: replication is fixed at the first install, peers need host networking and the shared secrets
PEER="$(openssl rand -hex 32)@10.10.0.6:3901"
# settings come from the conf file (sourced after the pinned defaults), so each case gets its own conf
C() { local f; f="$(mktemp "$W/conf.XXXX")"; { cat "$W/addons.conf"; printf '%s\n' "$@"; } > "$f"; echo "$f"; }
refuses "garage: replication must be 1, 2 or 3" "must be 1, 2 or 3" env ADDON_CONF="$(C GARAGE_REPLICATION=5)" "$A" plan garage --bind 10.10.0.5
refuses "garage: replication 3 refused in bridge mode" "needs ADDON_NETWORK=host" env ADDON_CONF="$(C GARAGE_REPLICATION=3 ADDON_NETWORK=bridge)" "$A" plan garage --bind 10.10.0.5
refuses "garage: malformed peer refused" "is not <64-hex" env ADDON_CONF="$(C GARAGE_PEERS=abc@10.10.0.6:3901)" "$A" plan garage --bind 10.10.0.5
refuses "garage: joining without the cluster's secrets.env refused" "copy secrets.env" env ADDON_CONF="$(C "GARAGE_PEERS=$PEER")" "$A" plan garage --bind 10.10.0.5
check "garage: replication 3 + peer plan ok with secrets.env present" bash -c "mkdir -p '$W/root/garage' && echo GARAGE_RPC_SECRET=x > '$W/root/garage/secrets.env' && ADDON_CONF='$(C GARAGE_REPLICATION=3 "GARAGE_PEERS=$PEER")' '$A' plan garage --bind 10.10.0.5 | grep -q 'replication 3, zone dc1, 1 peer'"
printf 'ADDON_NAME=garage\nGARAGE_REPLICATION=1\n' > "$W/root/garage/stack.env"
refuses "garage: replication cannot change on an installed cluster" "cannot change it in place" env ADDON_CONF="$(C GARAGE_REPLICATION=3)" "$A" plan garage --bind 10.10.0.5
rm -rf "$W/root/garage"
refuses "install without a terminal needs --yes" "without a terminal" bash -c "'$A' install gotenberg </dev/null"

L() { bash -c 'a="$1"; shift; ADDON_SOURCE_ONLY=1; set --; . "$a"; '"$1" _ "$A"; }
check "is_private_ip 10/8, 172.16/12, 192.168/16, 127/8" L 'is_private_ip 10.1.2.3 && is_private_ip 172.20.0.1 && is_private_ip 192.168.1.1 && is_private_ip 127.0.0.1'
check "is_private_ip rejects public and 172.32" L '! is_private_ip 8.8.8.8 && ! is_private_ip 172.32.0.1 && ! is_private_ip 1.2.3'
check "garage key id is GK + 24 hex" L '[[ "$(gen_value gk)" =~ ^GK[0-9a-f]{24}$ ]]'
check "write_secrets: 600, only adds missing keys" L "ADDONS_DIR=$W/s; mkdir -p $W/s/garage; write_secrets garage; a=\$(cat $W/s/garage/secrets.env); write_secrets garage; [ \"\$a\" = \"\$(cat $W/s/garage/secrets.env)\" ] && [ \"\$(perm $W/s/garage/secrets.env)\" = 600 ]"
check "garage.toml: replication and rpc_public_addr = ADDON_BIND in host mode" L "load_addon garage; ADDONS_DIR=$W/t; mkdir -p $W/t/garage; ADDON_BIND=10.10.0.5; GARAGE_REPLICATION=3; write_secrets garage; garage_toml $W/t/garage.toml; grep -qx 'replication_factor = 3' $W/t/garage.toml && grep -qxE 'rpc_(public|bind)_addr = .10.10.0.5:3901.' $W/t/garage.toml && [ \$(grep -cE '10.10.0.5:3901' $W/t/garage.toml) = 2 ]"

for f in "$ROOT"/stacks/addons/*/addon.env.example; do
  n="$(basename "$(dirname "$f")")"
  check "$n: image pinned to a version" bash -c "grep -E '^[A-Z]+_IMAGE=' '$f' | grep -vqE ':latest|=[^:]+\$'"
  c="$(dirname "$f")/docker-compose.yml"
  check "$n: compose publishes only on ADDON_BIND or 127.0.0.1" bash -c "grep -E '^ +- \"[^\"]*:[^\"]*:' '$c' | grep -vE '^ +- \"(\\\$\{ADDON_BIND:\?\}|127\.0\.0\.1):' | { ! grep -q .; }"
  check "$n: compose has no 0.0.0.0 publish" bash -c "! grep -E '\"0\.0\.0\.0:' '$c'"
  check "$n: compose sets a memory limit and no-new-privileges" bash -c "grep -q mem_limit '$c' && grep -q no-new-privileges '$c'"
  check "$n: compose has a healthcheck" grep -q healthcheck "$c"
done
echo "smoke-addons: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
