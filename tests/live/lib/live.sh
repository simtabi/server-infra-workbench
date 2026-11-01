# live.sh - shared framework for the live tests in tests/live (sourced, not run).
#
# A live test spends real money on DigitalOcean, so every one of them follows the same rules:
#   * dry run by default: prints the plan and the worst-case cost, creates nothing; --yes spends
#   * everything it creates carries the tag vsw-livetest plus a per-run tag vsw-livetest-<run>, and a
#     name starting vswlt-<run>-; teardown deletes only what carries BOTH (never by name match alone)
#   * teardown runs from an EXIT/INT/TERM trap, and a watchdog sends TERM after --timeout minutes, so
#     a hung step still ends in teardown; teardown then lists the account again and fails loudly on leftovers
#   * cost guard: hourly price of what it will create x the timeout must stay under --max-usd
#   * its own VPC (never the default one, never a VPC something else uses), a throwaway ssh key
#     made per run, a cloud firewall that allows ssh only from this machine's public address
#   * a region without any VPC is refused: the first VPC in a region becomes its default, and a
#     default VPC cannot be deleted. --create-default-vpc creates default-<region> first (free, kept)
#   * a cost log line per run in ~/.local/state/vsw-livetest/cost.log (outside the repo)
# Nothing secret is printed: keys and tokens go to 600 files in the run's temp dir, removed at the end.
# Public addresses of the throwaway droplets are not printed either (ssh goes through a generated config).
# shellcheck disable=SC2015
LIVE_TAG=vsw-livetest
LIVE_PREFIX=vswlt
LIVE_STATE="${LIVE_STATE:-$HOME/.local/state/vsw-livetest}"
LIVE_YES=0 LIVE_REGION="${LIVE_REGION:-tor1}" LIVE_MAX_USD="${LIVE_MAX_USD:-1.00}" LIVE_TIMEOUT_MIN="${LIVE_TIMEOUT_MIN:-45}"
LIVE_CREATE_DEFAULT_VPC=0 LIVE_SIZE="${LIVE_SIZE:-s-1vcpu-1gb}" LIVE_IMAGE="${LIVE_IMAGE:-ubuntu-24-04-x64}"
LIVE_TORN=0 LIVE_PASS=0 LIVE_WATCHDOG="" LIVE_VPC_ID="" LIVE_KEY_ID="" LIVE_FW_ID="" LIVE_T0=0 LIVE_HOURLY=0 LIVE_FIXED_USD=0
LIVE_CLEANUP_HOOKS=()

live_ok()   { LIVE_PASS=$((LIVE_PASS + 1)); echo "ok   $1"; }
live_fail() { echo "FAIL $1" >&2; exit 1; }
live_log()  { echo "--   $*"; }
live_die()  { echo "!! $*" >&2; exit 2; }

live_usage() {
  cat <<USAGE
usage: $0 [--yes] [--region R] [--size S] [--max-usd N] [--timeout MIN] [--create-default-vpc]
  default: dry run (plan + worst-case cost, nothing created)
  --yes                 create the resources, run the checks, tear everything down
  --region R            DigitalOcean region (default $LIVE_REGION; it must already have a VPC)
  --size S              droplet size (default $LIVE_SIZE)
  --max-usd N           refuse when the worst case (hourly x timeout) is above N (default $LIVE_MAX_USD)
  --timeout MIN         watchdog: tear down after MIN minutes whatever happens (default $LIVE_TIMEOUT_MIN)
  --create-default-vpc  the region has no VPC: create default-<region> first (free, kept)
USAGE
}
live_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) LIVE_YES=1 ;;
      --region) LIVE_REGION="${2:?}"; shift ;;
      --size) LIVE_SIZE="${2:?}"; shift ;;
      --max-usd) LIVE_MAX_USD="${2:?}"; shift ;;
      --timeout) LIVE_TIMEOUT_MIN="${2:?}"; shift ;;
      --create-default-vpc) LIVE_CREATE_DEFAULT_VPC=1 ;;
      -h|--help) live_usage; exit 0 ;;
      *) live_usage >&2; exit 2 ;;
    esac; shift
  done
  [[ "$LIVE_REGION" =~ ^[a-z]{3}[0-9]$ ]] || live_die "bad --region $LIVE_REGION"
  [[ "$LIVE_TIMEOUT_MIN" =~ ^[0-9]+$ ]] && [ "$LIVE_TIMEOUT_MIN" -ge 5 ] && [ "$LIVE_TIMEOUT_MIN" -le 240 ] || live_die "--timeout takes 5..240 minutes"
  [[ "$LIVE_MAX_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || live_die "bad --max-usd"
}

live_need() { local c; for c in doctl jq ssh ssh-keygen curl python3 openssl; do command -v "$c" >/dev/null 2>&1 || live_die "needs $c"; done
  doctl account get -o json >/dev/null 2>&1 || live_die "doctl is not authenticated (doctl auth init)"; }
live_usd() { python3 -c 'import sys; print("%.2f" % float(sys.argv[1]))' "$1"; }
live_gt() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' "$1" "$2"; }
live_size_hourly() { doctl compute size list -o json | jq -r --arg s "$1" '.[] | select(.slug == $s) | .price_hourly'; }
live_mtd() { doctl balance get -o json 2>/dev/null | jq -r '.month_to_date_usage // "?"'; }
live_id() { jq -r 'if type == "array" then .[0].id else .id end'; }   # doctl -o json: one object or a one-item array, per command
# live_create CMD...: a doctl create with -o json; prints the new id. doctl writes API errors as JSON
# to stdout, so on failure show the API's reason instead of failing silently.
live_create() {
  local out; if ! out="$("$@" -o json 2>&1)"; then live_api_err "$out"; return 1; fi
  live_id <<<"$out"
}
live_api_err() { echo "!! DigitalOcean: $(jq -r '.errors[0].reason // .errors[0].detail // empty' <<<"$1" 2>/dev/null || head -c 300 <<<"$1")" >&2; }

# live_begin NAME DROPLETS [FIXED_USD]: checks, plan, cost guard; dry run exits 0 here
live_begin() {
  LIVE_NAME="$1"; local n="$2" fixed="${3:-0}" ph worst
  live_need
  LIVE_RUN="$(date -u +%m%d%H%M)-$(openssl rand -hex 2)"
  LIVE_RUN_TAG="$LIVE_TAG-$LIVE_RUN"; LIVE_NP="$LIVE_PREFIX-$LIVE_RUN"
  LIVE_HOURLY=0
  if [ "$n" -gt 0 ]; then
    ph="$(live_size_hourly "$LIVE_SIZE")"; [ -n "$ph" ] || live_die "unknown size $LIVE_SIZE"
    doctl compute size list -o json | jq -e --arg s "$LIVE_SIZE" --arg r "$LIVE_REGION" '.[] | select(.slug == $s) | .regions | index($r)' >/dev/null \
      || live_die "size $LIVE_SIZE is not offered in $LIVE_REGION right now (try --region tor1 or --size)"
    LIVE_HOURLY="$(python3 -c 'import sys; print(float(sys.argv[1]) * int(sys.argv[2]))' "$ph" "$n")"
  fi
  LIVE_FIXED_USD="$fixed"
  # droplets bill per started hour (minimum one hour)
  worst="$(python3 -c 'import sys,math; h=float(sys.argv[1]); t=int(sys.argv[2]); f=float(sys.argv[3]); print(h * max(1, math.ceil(t / 60)) + f)' "$LIVE_HOURLY" "$LIVE_TIMEOUT_MIN" "$fixed")"
  echo "== live test: $LIVE_NAME  run $LIVE_RUN"
  [ "$n" -gt 0 ] && echo "   region $LIVE_REGION, $n droplet(s) $LIVE_SIZE ($LIVE_IMAGE), tag $LIVE_TAG + $LIVE_RUN_TAG"
  local fx=""; [ "$fixed" = 0 ] || fx=", + \$$(live_usd "$fixed") fixed"
  echo "   worst case: \$$(live_usd "$worst") (hourly \$$(live_usd "$LIVE_HOURLY") x $LIVE_TIMEOUT_MIN min timeout, rounded up to hours$fx); limit \$$LIVE_MAX_USD"
  live_gt "$worst" "$LIVE_MAX_USD" && live_die "worst case \$$(live_usd "$worst") is above --max-usd $LIVE_MAX_USD"
  if [ "$n" -gt 0 ]; then live_vpc_region_check; fi
  if [ "$LIVE_YES" != 1 ]; then echo "   dry run: nothing created. Add --yes to run it (and spend up to the worst case)."; exit 0; fi
  LIVE_W="$(mktemp -d "${TMPDIR:-/tmp}/vswlt.XXXXXX")"; chmod 700 "$LIVE_W"
  mkdir -p "$LIVE_STATE"; chmod 700 "$LIVE_STATE"
  LIVE_T0="$(date +%s)"; LIVE_MTD0="$(live_mtd)"
  printf '%s start %s run=%s region=%s droplets=%s size=%s hourly=%s fixed=%s mtd=%s\n' "$(date -u +%FT%TZ)" "$LIVE_NAME" "$LIVE_RUN" "$LIVE_REGION" "$n" "$LIVE_SIZE" "$LIVE_HOURLY" "$fixed" "$LIVE_MTD0" >> "$LIVE_STATE/cost.log"
  trap 'live_teardown' EXIT
  trap 'echo "!! interrupted: tearing down" >&2; exit 130' INT
  trap 'echo "!! timeout or TERM: tearing down" >&2; exit 124' TERM
  trap 'echo "!! hangup: tearing down" >&2; exit 129' HUP
  # the watchdog's sleep dies with it (no orphan sleep left to fire at a reused pid)
  ( sp=""; trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM INT
    sleep $((LIVE_TIMEOUT_MIN * 60)) & sp=$!; wait "$sp" || exit 0
    echo "!! watchdog: $LIVE_TIMEOUT_MIN min reached" >&2; kill -TERM $$ ) 2>/dev/null &
  LIVE_WATCHDOG=$!
}

# ---- VPC --------------------------------------------------------------------------------------
live_vpc_region_check() {
  local nd; nd="$(doctl vpcs list -o json | jq --arg r "$LIVE_REGION" '[.[] | select(.region == $r)] | length')"
  if [ "$nd" = 0 ]; then
    [ "$LIVE_CREATE_DEFAULT_VPC" = 1 ] || live_die "$LIVE_REGION has no VPC yet: the first one becomes the region's default and cannot be deleted. Re-run with --create-default-vpc (creates default-$LIVE_REGION, free, kept) or pick a region that has one"
    if [ "$LIVE_YES" = 1 ]; then
      doctl vpcs create --name "default-$LIVE_REGION" --region "$LIVE_REGION" --description "region default (created before a vsw live test)" -o json >/dev/null \
        || live_die "could not create default-$LIVE_REGION"
      echo "   created VPC default-$LIVE_REGION (the region default; kept, VPCs are free)"
    else echo "   would create VPC default-$LIVE_REGION first (--create-default-vpc)"; fi
  fi
  if [ "$LIVE_YES" = 1 ] || [ "$nd" != 0 ]; then
    doctl vpcs list -o json | jq -e --arg r "$LIVE_REGION" '[.[] | select(.region == $r and .default == true)] | length == 1' >/dev/null \
      || { [ "$LIVE_YES" != 1 ] && [ "$nd" = 0 ]; } || live_die "$LIVE_REGION has VPCs but no default one"
  fi
}
live_free_range() { # a /24 in 10.0.0.0/8 that overlaps no VPC in the account
  doctl vpcs list -o json | jq -r '.[].ip_range' | python3 -c '
import ipaddress, random, sys
used = [ipaddress.ip_network(l.strip()) for l in sys.stdin if l.strip()]
for _ in range(500):
    n = ipaddress.ip_network("10.%d.%d.0/24" % (random.randint(200, 250), random.randint(0, 255)))
    if not any(n.overlaps(u) for u in used):
        print(n); break
else:
    sys.exit(1)'
}
live_vpc_create() {
  local range; range="$(live_free_range)" || live_die "no free /24 for the test VPC"
  LIVE_VPC_CIDR="$range"
  LIVE_VPC_ID="$(live_create doctl vpcs create --name "$LIVE_NP-vpc" --region "$LIVE_REGION" --ip-range "$range" \
    --description "$LIVE_RUN_TAG throwaway")" || live_die "VPC create failed"
  [ -n "$LIVE_VPC_ID" ] && [ "$LIVE_VPC_ID" != null ] || live_die "VPC create failed"
  # the API omits "default" when it is false, so a missing field means not the default
  doctl vpcs get "$LIVE_VPC_ID" -o json | jq -e '(.[0] // .) | (.default // false) == false' >/dev/null || live_die "the new VPC came out as the region default: refusing to use it"
  echo "$LIVE_VPC_ID" > "$LIVE_W/vpc.id"
  live_ok "VPC $LIVE_NP-vpc ($range), not the region default"
}

# ---- ssh key, firewall, droplets --------------------------------------------------------------
live_sshkey_create() {
  ssh-keygen -q -t ed25519 -N '' -C "$LIVE_NP" -f "$LIVE_W/id" >/dev/null
  LIVE_KEY_ID="$(live_create doctl compute ssh-key import "$LIVE_NP-key" --public-key-file "$LIVE_W/id.pub")" || live_die "ssh key import failed"
  [[ "$LIVE_KEY_ID" =~ ^[0-9]+$ ]] || live_die "ssh key import failed"
  echo "$LIVE_KEY_ID" > "$LIVE_W/key.id"
  : > "$LIVE_W/known_hosts"; : > "$LIVE_W/ssh_config"; chmod 600 "$LIVE_W/ssh_config" "$LIVE_W/known_hosts"
  # ssh/scp wrappers first on PATH: tools that shell out to plain `ssh HOST` (the --host mode) use this run's config
  mkdir -p "$LIVE_W/bin"
  printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v ssh)" "$LIVE_W/ssh_config" > "$LIVE_W/bin/ssh"
  printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v scp)" "$LIVE_W/ssh_config" > "$LIVE_W/bin/scp"
  chmod 700 "$LIVE_W/bin/ssh" "$LIVE_W/bin/scp"; PATH="$LIVE_W/bin:$PATH"; export PATH
  live_ok "throwaway ssh key $LIVE_NP-key (made for this run)"
}
live_firewall_create() { # ssh from this machine only; everything inside the test VPC
  local me; me="$(curl -fsS --max-time 10 https://api.ipify.org)" || live_die "cannot find this machine's public IPv4"
  [[ "$me" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || live_die "odd public address"
  # a firewall can only name tags that already exist (the droplets get them later)
  local t; for t in "$LIVE_TAG" "$LIVE_RUN_TAG"; do
    doctl compute tag create "$t" -o json >/dev/null 2>&1 || live_die "could not create tag $t"; done
  LIVE_FW_ID="$(live_create doctl compute firewall create --name "$LIVE_NP-fw" --tag-names "$LIVE_RUN_TAG" \
    --inbound-rules "protocol:tcp,ports:22,address:$me/32 protocol:tcp,ports:all,address:$LIVE_VPC_CIDR protocol:udp,ports:all,address:$LIVE_VPC_CIDR protocol:icmp,address:$LIVE_VPC_CIDR" \
    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,address:0.0.0.0/0,address:::/0" \
    )" || live_die "firewall create failed"
  [ -n "$LIVE_FW_ID" ] && [ "$LIVE_FW_ID" != null ] || live_die "firewall create failed"
  echo "$LIVE_FW_ID" > "$LIVE_W/fw.id"
  live_ok "cloud firewall $LIVE_NP-fw: ssh from this machine only, all traffic inside the VPC"
}
# live_droplets_create n1 n2 ...: names become vswlt-<run>-n1 ...; ssh aliases are the short names
live_droplets_create() {
  local names=() s; for s in "$@"; do names+=("$LIVE_NP-$s"); done
  doctl compute droplet create "${names[@]}" --region "$LIVE_REGION" --size "$LIVE_SIZE" --image "$LIVE_IMAGE" \
    --vpc-uuid "$LIVE_VPC_ID" --ssh-keys "$LIVE_KEY_ID" --tag-names "$LIVE_TAG,$LIVE_RUN_TAG" --wait -o json > "$LIVE_W/droplets.json" 2> "$LIVE_W/droplets.err" \
    || { live_api_err "$(cat "$LIVE_W/droplets.json" "$LIVE_W/droplets.err")"; live_die "droplet create failed"; }
  for s in "$@"; do
    local pub priv
    pub="$(jq -r --arg n "$LIVE_NP-$s" '.[] | select(.name == $n) | .networks.v4[] | select(.type == "public") | .ip_address' "$LIVE_W/droplets.json" | head -1)"
    priv="$(jq -r --arg n "$LIVE_NP-$s" '.[] | select(.name == $n) | .networks.v4[] | select(.type == "private") | .ip_address' "$LIVE_W/droplets.json" | head -1)"
    [ -n "$pub" ] && [ -n "$priv" ] || live_die "no addresses for $s"
    printf 'Host %s\n  HostName %s\n  User root\n  IdentityFile %s\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n  StrictHostKeyChecking accept-new\n  ConnectTimeout 10\n  ServerAliveInterval 15\n  LogLevel ERROR\n' \
      "$s" "$pub" "$LIVE_W/id" "$LIVE_W/known_hosts" >> "$LIVE_W/ssh_config"
    echo "$priv" > "$LIVE_W/$s.private"
  done
  for s in "$@"; do
    local i up=0; for i in $(seq 1 60); do ssh -o BatchMode=yes "$s" 'cloud-init status --wait >/dev/null 2>&1; true' >/dev/null 2>&1 && { up=1; break; }; sleep 5; done
    [ "$up" = 1 ] || live_die "$s: ssh never came up ($i tries)"
  done
  live_ok "$# droplet(s) up in the test VPC, ssh with the run key: $*"
}
live_private_ip() { cat "$LIVE_W/$1.private"; }
live_ssh() { local h="$1"; shift; ssh -o BatchMode=yes "$h" "$@"; }

# ---- teardown ---------------------------------------------------------------------------------
live_guarded_droplets() { # ids of droplets with the run tag; refuse if one does not look like ours
  local js; js="$(doctl compute droplet list --tag-name "$LIVE_RUN_TAG" -o json 2>/dev/null || echo '[]')"
  [ -n "$js" ] || js='[]'
  if jq -e --arg p "$LIVE_NP-" --arg t "$LIVE_TAG" '[.[] | select((.name | startswith($p) | not) or ((.tags // []) | index($t) | not))] | length > 0' <<<"$js" >/dev/null; then
    echo "!! a droplet tagged $LIVE_RUN_TAG does not carry the $LIVE_NP- name and $LIVE_TAG tag: NOT deleting anything by tag; check the account" >&2
    return 1
  fi
  jq -r '.[].id' <<<"$js"
}
live_retry_delete() { # CMD...: a delete can fail while the droplets using the thing are still going away
  local i out; for i in $(seq 1 12); do
    out="$("$@" 2>&1)" && return 0
    grep -qiE 'not.?found|404' <<<"$out" && return 0; sleep 5; done
  live_api_err "$out"; return 0
}
live_teardown() {
  local rc=$? left=0 ids id i
  [ "$LIVE_TORN" = 1 ] && return; LIVE_TORN=1
  # a second Ctrl-C, TERM or hangup must not cut the teardown short and orphan paid resources
  trap - EXIT; trap '' INT TERM HUP
  [ -n "$LIVE_WATCHDOG" ] && kill "$LIVE_WATCHDOG" 2>/dev/null || true
  echo "== teardown ($LIVE_NAME, run $LIVE_RUN)"
  for i in "${LIVE_CLEANUP_HOOKS[@]+"${LIVE_CLEANUP_HOOKS[@]}"}"; do "$i" || { echo "!! cleanup hook $i failed" >&2; left=1; }; done
  if ids="$(live_guarded_droplets)"; then
    for id in $ids; do doctl compute droplet delete "$id" --force >/dev/null 2>&1 || true; done
    for i in $(seq 1 60); do [ -z "$(live_guarded_droplets 2>/dev/null)" ] && break; sleep 5; done
  else left=1; fi
  [ -n "$LIVE_FW_ID" ] || LIVE_FW_ID="$(cat "$LIVE_W/fw.id" 2>/dev/null || true)"
  [ -n "$LIVE_FW_ID" ] && live_retry_delete doctl compute firewall delete "$LIVE_FW_ID" --force
  [ -n "$LIVE_KEY_ID" ] || LIVE_KEY_ID="$(cat "$LIVE_W/key.id" 2>/dev/null || true)"
  [ -n "$LIVE_KEY_ID" ] && live_retry_delete doctl compute ssh-key delete "$LIVE_KEY_ID" --force
  [ -n "$LIVE_VPC_ID" ] || LIVE_VPC_ID="$(cat "$LIVE_W/vpc.id" 2>/dev/null || true)"
  if [ -n "$LIVE_VPC_ID" ]; then   # a VPC can be deleted only when its last member is gone (takes a while)
    for i in $(seq 1 36); do doctl vpcs delete "$LIVE_VPC_ID" --force >/dev/null 2>&1 && break; sleep 5; done
  fi
  doctl compute tag delete "$LIVE_RUN_TAG" --force >/dev/null 2>&1 || true
  # the shared base tag too, once nothing carries it (another run may be using it)
  [ "$(doctl compute tag get "$LIVE_TAG" -o json 2>/dev/null | jq -r '(if type == "array" then .[0] else . end).resources.count // 0' 2>/dev/null)" = 0 ] \
    && doctl compute tag delete "$LIVE_TAG" --force >/dev/null 2>&1 || true
  # verify: list the account again
  local d f k v
  for i in $(seq 1 12); do
  d="$(doctl compute droplet list -o json | jq -r --arg p "$LIVE_NP-" '[.[] | select(.name | startswith($p))] | length')"
  f="$(doctl compute firewall list -o json | jq -r --arg p "$LIVE_NP-" '[.[] | select(.name | startswith($p))] | length')"
  k="$(doctl compute ssh-key list -o json | jq -r --arg p "$LIVE_NP-" '[.[] | select(.name | startswith($p))] | length')"
  v="$(doctl vpcs list -o json | jq -r --arg p "$LIVE_NP-" '[.[] | select(.name | startswith($p))] | length')"
  [ "$d$f$k$v" = 0000 ] && break; sleep 5; done   # listings can lag a deletion
  if [ "$d$f$k$v" = 0000 ] && [ "$left" = 0 ]; then echo "teardown verified: no $LIVE_NP-* droplet, firewall, ssh key or VPC left"
  else echo "!! LEFTOVERS: droplets=$d firewalls=$f ssh-keys=$k vpcs=$v; run: tests/live/sweep.sh --yes" >&2; [ "$rc" = 0 ] && rc=3; fi
  local secs=$(( $(date +%s) - LIVE_T0 )) est
  est="$(python3 -c 'import sys,math; print(float(sys.argv[1]) * max(1, math.ceil(int(sys.argv[2]) / 3600)) + float(sys.argv[3]))' "$LIVE_HOURLY" "$secs" "$LIVE_FIXED_USD")"
  printf '%s end   %s run=%s rc=%s secs=%s est_usd=%s leftovers=%s%s%s%s mtd_before=%s\n' "$(date -u +%FT%TZ)" "$LIVE_NAME" "$LIVE_RUN" "$rc" "$secs" "$(live_usd "$est")" "$d" "$f" "$k" "$v" "$LIVE_MTD0" >> "$LIVE_STATE/cost.log"
  echo "cost: ~\$$(live_usd "$est") (billed per started hour; ran $((secs / 60)) min); log: $LIVE_STATE/cost.log"
  rm -rf "$LIVE_W"
  exit "$rc"
}
