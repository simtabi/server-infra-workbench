#!/usr/bin/env bash
# Integration test of src/shell/addons/addon.sh against throwaway containers (Docker/OrbStack).
# Not part of `make ci` (needs Docker, ~2 min): run by `make it`. Covers Gotenberg (PDF, SSRF guard,
# basic auth), Garage (layout, bucket, least-privilege key, idempotent re-install) and SeaweedFS
# (bucket-scoped identity) and RustFS (experimental gate, bucket-scoped app key, console on loopback).
# Names and ports follow SIWO_IT_PREFIX (tests/shell/it-lib.sh), so a parallel run does not collide.
# shellcheck disable=SC2015
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "addons-it skipped (no docker)"; exit 0; }
A="$PWD/src/shell/addons/addon.sh"
W="$(mktemp -d /tmp/siw-addons-it.XXXX)"; P="$(it_name "")"; LAST="/tmp/$P-addons-it-last"
PG=$(it_port 23000); PGA=$(it_port 23900); PSW=$(it_port 22535); PRF=$(it_port 29000); PRC=$(it_port 29001)
it_ports_free "$PG" "$PGA" "$(it_port 23903)" "$(it_port 28333)" "$PSW" "$PRF" "$PRC" || exit 1
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() {
  it_purge "$P-gotenberg" "$P-garage" "$P-seaweedfs" "$P-rustfs"
  rm -rf "$LAST"; mkdir -p "$LAST"; cp "$W"/*.out "$LAST/" 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT
cat > "$W/addons.conf" <<CONF
ADDONS_DIR=$W/root
AUDIT_LOG=$W/audit.log
ADDON_BIND=127.0.0.1
ADDON_NETWORK=bridge
ADDON_PROJECT_PREFIX=$P
GOTENBERG_PORT=$PG
GARAGE_S3_PORT=$PGA
GARAGE_ADMIN_PORT=$(it_port 23903)
SEAWEED_S3_PORT=$(it_port 28333)
SEAWEED_ADMIN_PORT=$PSW
RUSTFS_PORT=$PRF
RUSTFS_CONSOLE_PORT=$PRC
STORAGE_BUCKET=itbucket
ADDON_DISK_WARN_PCT=100
ADDON_DISK_BAD_PCT=100
CONF
export ADDON_CONF="$W/addons.conf" ADDON_ALLOW_NONROOT=1
ad() { "$A" "$@"; }
# signed S3 request with the app key from a laravel.env file; credentials go through curl's stdin config
s3() { local f="$1" m="$2" u="$3"; shift 3
  printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:%s:s3"\n' "$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$f")" \
    "$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' "$f")" "$(sed -n 's/^AWS_DEFAULT_REGION=//p' "$f")" \
    | curl -s -o "$W/s3.body" -w '%{http_code}' -K - -X "$m" "$u" "$@"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
echo "hello from addons-it" > "$W/obj.txt"

# ---- gotenberg ----------------------------------------------------------------------------
ad plan gotenberg > "$W/plan.out" 2>&1 && [ ! -e "$W/root/gotenberg" ] && ok "plan writes nothing" || { cat "$W/plan.out"; fail "plan"; }
ad install gotenberg --yes > "$W/g1.out" 2>&1 && ok "gotenberg: install (pinned $(grep -o 'gotenberg/gotenberg:[0-9.]*' "$W/plan.out" | head -1))" || { it_why "$W/g1.out" 30; fail "gotenberg install"; }
printf '<html><body><h1>invoice</h1></body></html>' > "$W/index.html"
[ "$(curl -s -o "$W/o.pdf" -w '%{http_code}' -F files=@"$W/index.html" "http://127.0.0.1:$PG/forms/chromium/convert/html")" = 200 ] \
  && [ "$(head -c 5 "$W/o.pdf")" = "%PDF-" ] && ok "gotenberg: HTML -> PDF" || fail "gotenberg convert"
[ "$(curl -s -o /dev/null -w '%{http_code}' -F url=http://127.0.0.1:3000/health "http://127.0.0.1:$PG/forms/chromium/convert/url")" = 403 ] \
  && ok "gotenberg: SSRF guard refuses a private-IP URL (403)" || fail "gotenberg SSRF guard"
ad doctor gotenberg > "$W/gd.out" 2>&1 && grep -q '0 problem' "$W/gd.out" && ok "gotenberg: doctor clean" || { cat "$W/gd.out"; fail "gotenberg doctor"; }
echo "GOTENBERG_BASIC_AUTH=true" >> "$W/addons.conf"
ad install gotenberg --yes > "$W/g2.out" 2>&1 || { it_why "$W/g2.out" 30; fail "gotenberg re-install with auth"; }
ad laravel-env gotenberg --out "$W/g.env" > "$W/ge.out" 2>&1
pw="$(sed -n 's/^GOTENBERG_PASSWORD=//p' "$W/g.env")"; us="$(sed -n 's/^GOTENBERG_USERNAME=//p' "$W/g.env")"
[ "$(curl -s -o /dev/null -w '%{http_code}' -F files=@"$W/index.html" "http://127.0.0.1:$PG/forms/chromium/convert/html")" = 401 ] \
  && [ "$(printf 'user = "%s:%s"\n' "$us" "$pw" | curl -s -o /dev/null -w '%{http_code}' -K - -F files=@"$W/index.html" "http://127.0.0.1:$PG/forms/chromium/convert/html")" = 200 ] \
  && ok "gotenberg: basic auth on -> anonymous 401, generated credentials 200" || fail "gotenberg basic auth"
[ "$(mode "$W/g.env")" = 600 ] && [ "$(mode "$W/root/gotenberg/secrets.env")" = 600 ] && ! grep -q "$pw" "$W"/g*.out \
  && ok "gotenberg: laravel-env + secrets are 600, password never printed" || fail "gotenberg secret handling"

# ---- garage -------------------------------------------------------------------------------
ad install garage --role web --yes > "$W/ga1.out" 2>&1 && grep -q 'garage: app key' "$W/ga1.out" && ok "garage: install, layout, bucket, app key" || { it_why "$W/ga1.out" 30; fail "garage install"; }
ad laravel-env garage --out "$W/ga.env" > "$W/gae.out" 2>&1; ep="$(sed -n 's/^AWS_ENDPOINT=//p' "$W/ga.env")"
grep -q '^AWS_USE_PATH_STYLE_ENDPOINT=true' "$W/ga.env" && [ "$ep" = "http://127.0.0.1:$PGA" ] && ok "garage: Laravel keys (endpoint, path style)" || fail "garage laravel-env"
[ "$(s3 "$W/ga.env" PUT "$ep/itbucket/a.txt" --data-binary @"$W/obj.txt")" = 200 ] && [ "$(s3 "$W/ga.env" GET "$ep/itbucket/a.txt")" = 200 ] \
  && cmp -s "$W/s3.body" "$W/obj.txt" && ok "garage: app key writes and reads its bucket" || fail "garage put/get"
[ "$(s3 "$W/ga.env" PUT "$ep/otherbucket")" = 403 ] && [ "$(s3 "$W/ga.env" DELETE "$ep/itbucket")" = 403 ] \
  && [ "$(curl -s -o /dev/null -w '%{http_code}' "$ep/itbucket/a.txt")" = 403 ] && ok "garage: app key cannot create/delete buckets; anonymous denied" || fail "garage least privilege"
ad install garage --role web --yes > "$W/ga2.out" 2>&1 && ! grep -qE 'garage: (layout|bucket|app key)' "$W/ga2.out" \
  && [ "$(s3 "$W/ga.env" GET "$ep/itbucket/a.txt")" = 200 ] && ok "garage: re-install is idempotent (same key, data kept)" || { it_why "$W/ga2.out" 20; fail "garage idempotent"; }
ad doctor garage > "$W/gad.out" 2>&1 && grep -q '0 problem' "$W/gad.out" && ok "garage: doctor clean" || { cat "$W/gad.out"; fail "garage doctor"; }
if ad plan seaweedfs > "$W/excl.out" 2>&1; then fail "second object store accepted"; fi
grep -q 'already installed' "$W/excl.out" && ok "one object store per node" || fail "exclusivity"
ad remove garage --yes > "$W/gar.out" 2>&1 && ls -d "$W"/root/.removed-garage-* >/dev/null && ok "garage: remove keeps data + credentials" || { cat "$W/gar.out"; fail "garage remove"; }

# ---- seaweedfs ----------------------------------------------------------------------------
ad install seaweedfs --role web --yes > "$W/s1.out" 2>&1 && ok "seaweedfs: install, bucket, bucket-scoped identity" || { it_why "$W/s1.out" 30; fail "seaweedfs install"; }
ad laravel-env seaweedfs --out "$W/s.env" > /dev/null 2>&1; ep="$(sed -n 's/^AWS_ENDPOINT=//p' "$W/s.env")"
[ "$(s3 "$W/s.env" PUT "$ep/itbucket/a.txt" --data-binary @"$W/obj.txt")" = 200 ] && [ "$(s3 "$W/s.env" GET "$ep/itbucket/a.txt")" = 200 ] \
  && cmp -s "$W/s3.body" "$W/obj.txt" && ok "seaweedfs: app key writes and reads its bucket" || fail "seaweedfs put/get"
echo "s3.bucket.create -name other" | (cd "$W/root/seaweedfs" && docker compose -p "$P-seaweedfs" --env-file stack.env --env-file secrets.env exec -T seaweedfs weed shell -master=127.0.0.1:9333 -filer=127.0.0.1:8888) >/dev/null 2>&1 \
  || fail "seaweedfs: creating a second bucket for the least-privilege check"
[ "$(s3 "$W/s.env" PUT "$ep/other/x.txt" --data-binary @"$W/obj.txt")" = 403 ] && [ "$(s3 "$W/s.env" DELETE "$ep/itbucket")" = 403 ] \
  && [ "$(curl -s -o /dev/null -w '%{http_code}' "$ep/itbucket/a.txt")" = 403 ] && ok "seaweedfs: app key denied on another bucket and bucket delete; anonymous denied" || fail "seaweedfs least privilege"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PSW/")" != 200 ] && ok "seaweedfs: admin UI on 127.0.0.1 asks for a login" || fail "seaweedfs admin auth"
ad doctor seaweedfs > "$W/sd.out" 2>&1 && grep -q '0 problem' "$W/sd.out" && ok "seaweedfs: doctor clean" || { cat "$W/sd.out"; fail "seaweedfs doctor"; }

# ---- rustfs (experimental) ---------------------------------------------------------------
ad remove seaweedfs --yes > "$W/sr.out" 2>&1 || { cat "$W/sr.out"; fail "seaweedfs remove"; }
if ad install rustfs --yes > "$W/r0.out" 2>&1; then fail "rustfs installed without --accept-experimental"; fi
grep -q EXPERIMENTAL "$W/r0.out" && [ ! -e "$W/root/rustfs/docker-compose.yml" ] && ok "rustfs: refused without --accept-experimental, nothing written" || { cat "$W/r0.out"; fail "rustfs gate"; }
ad install rustfs --yes --accept-experimental > "$W/r1.out" 2>&1 && grep -q 'rustfs: bucket itbucket' "$W/r1.out" && grep -q 'rustfs: app key' "$W/r1.out" \
  && ok "rustfs: install (pinned $(sed -n 's/^RUSTFS_IMAGE=//p' "$W/root/rustfs/stack.env")), bucket and bucket-scoped app key" || { it_why "$W/r1.out" 30; fail "rustfs install"; }
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_DEFAULT_REGION=us-east-1\n' "$(sed -n 's/^RUSTFS_ACCESS_KEY=//p' "$W/root/rustfs/secrets.env")" \
  "$(sed -n 's/^RUSTFS_SECRET_KEY=//p' "$W/root/rustfs/secrets.env")" > "$W/r.root"; chmod 600 "$W/r.root"
[ "$(s3 "$W/r.root" PUT "http://127.0.0.1:$PRF/itbucket/a.txt" --data-binary @"$W/obj.txt")" = 200 ] && [ "$(s3 "$W/r.root" GET "http://127.0.0.1:$PRF/itbucket/a.txt")" = 200 ] \
  && cmp -s "$W/s3.body" "$W/obj.txt" && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PRF/itbucket/a.txt")" = 403 ] \
  && ok "rustfs: signed put/get works, anonymous denied" || fail "rustfs s3"
ad laravel-env rustfs --out "$W/r.env" > "$W/re.out" 2>&1; rk="$(sed -n 's/^RUSTFS_SECRET_KEY=//p' "$W/root/rustfs/secrets.env")"
ep="$(sed -n 's/^AWS_ENDPOINT=//p' "$W/r.env")"
! grep -qF "$rk" "$W/r.env" && grep -q 'bucket-scoped app key' "$W/r.env" && [ -n "$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$W/r.env")" ] \
  && [ "$ep" = "http://127.0.0.1:$PRF" ] && ok "rustfs: laravel-env writes the app key, never the root key" || fail "rustfs laravel-env"
[ "$(s3 "$W/r.env" PUT "$ep/itbucket/b.txt" --data-binary @"$W/obj.txt")" = 200 ] && [ "$(s3 "$W/r.env" GET "$ep/itbucket/a.txt")" = 200 ] \
  && cmp -s "$W/s3.body" "$W/obj.txt" && ok "rustfs: app key writes and reads its bucket (and sees objects the root key wrote)" || fail "rustfs app put/get"
[ "$(s3 "$W/r.env" PUT "$ep/otherbucket")" = 403 ] && [ "$(s3 "$W/r.env" DELETE "$ep/itbucket")" = 403 ] \
  && [ "$(s3 "$W/r.env" GET "$ep/rustfs/admin/v3/list-users")" = 403 ] && ok "rustfs: app key cannot create/delete buckets or call the admin API" || fail "rustfs least privilege"
ad install rustfs --yes --accept-experimental > "$W/r2.out" 2>&1 && ! grep -q 'rustfs: app key' "$W/r2.out" \
  && [ "$(s3 "$W/r.env" GET "$ep/itbucket/b.txt")" = 200 ] && ok "rustfs: re-install is idempotent (same app key, data kept)" || { it_why "$W/r2.out" 20; fail "rustfs idempotent"; }
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PRC/" || true)" != 000 ] && docker port "$(docker ps -q --filter "label=com.docker.compose.project=$P-rustfs")" | grep -q "127.0.0.1:$PRC" \
  && ok "rustfs: console on 127.0.0.1 only" || fail "rustfs console"
ad doctor rustfs > "$W/rd.out" 2>&1 && grep -q '0 problem' "$W/rd.out" && grep -q 'experimental' "$W/rd.out" && grep -q 'app key exists' "$W/rd.out" && ok "rustfs: doctor clean, app key present, flags experimental" || { cat "$W/rd.out"; fail "rustfs doctor"; }

# ---- secrets never reach stdout or the audit log ---------------------------------------------
leak=0; for f in "$W"/root/*/secrets.env "$W"/root/.removed-*/secrets.env; do
  while IFS='=' read -r k v; do case "$k" in ""|\#*) continue ;; esac; [ "${#v}" -ge 8 ] || continue
    grep -qF -- "$v" "$W"/*.out "$W/audit.log" 2>/dev/null && { echo "leak: $k"; leak=1; }; done < "$f"; done
[ "$leak" = 0 ] && ok "no generated secret appears in any output or the audit log" || fail "secret leak"
grep -q 'install ok' "$W/audit.log" && ok "audit log records installs and removals" || fail "audit log"
echo "addons-it: $pass checks passed"
