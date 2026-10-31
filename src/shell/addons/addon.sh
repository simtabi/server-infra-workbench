#!/usr/bin/env bash
# addon.sh - optional services next to a Laravel app: Gotenberg (PDF) and ONE S3-compatible object store
# (Garage, SeaweedFS, or the experimental RustFS). Runs as root ON the node that hosts the add-on.
#
#   addon.sh list                                    add-ons, kind, default role, pinned image, installed?
#   addon.sh plan    <name> [--role R] [--bind IP]   what install would do (writes nothing, shows no secrets)
#   addon.sh install <name> [--role R] [--bind IP] [--data-dir D] [--yes]
#                                                    plan, confirm, creds (600), start, bucket + app key, health
#   addon.sh status  [name]                          containers and health
#   addon.sh doctor  [name]                          binding, pin, perms, health, auth, RAM, disk (exit 1 on a problem)
#   addon.sh laravel-env <name> [--out FILE]         Laravel .env keys into FILE (chmod 600); values never printed
#   addon.sh remove  <name> [--delete-data] [--yes]  stop and remove; data kept unless --delete-data (typed name)
#
# Roles: web = same node as PHP, binds 127.0.0.1 | db, dedicated = binds the private (VPC) IP.
# Config: /etc/vsw-addons.conf (or ADDON_CONF=FILE); keys in config/addons.conf.example.
# Every change is appended to the audit log (/var/log/vsw-addons.log). Secrets never reach stdout or the log.
# shellcheck disable=SC2015  # ok/bad/dwarn/die always return 0 or exit, so A && B || C is safe here
set -euo pipefail

VERSION="1.0.0"
ADDONS="gotenberg garage seaweedfs rustfs"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
ADDON_CONF="${ADDON_CONF:-/etc/vsw-addons.conf}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!! WARNING: %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit "${CODE:-1}"; }
usage() { sed -n '2,17p' "$SELF" | sed 's/^# \{0,1\}//'; }
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
owner_uid() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
hex() { openssl rand -hex "$1"; }

load_conf() { # the conf is sourced, so it must be trustworthy
  [ -f "$ADDON_CONF" ] || return 0
  if [ "$(id -u)" -eq 0 ]; then
    [ "$(owner_uid "$ADDON_CONF")" = 0 ] || die "$ADDON_CONF must be owned by root"
    case "$(perm "$ADDON_CONF")" in *[2367]) die "$ADDON_CONF is world-writable; chmod 600 it" ;; esac
  fi
  # shellcheck disable=SC1090
  . "$ADDON_CONF"
}
defaults() {
  ADDONS_DIR="${ADDONS_DIR:-/opt/vsw-addons}"
  AUDIT_LOG="${AUDIT_LOG:-/var/log/vsw-addons.log}"
  STORAGE_BUCKET="${STORAGE_BUCKET:-app}"
  ADDON_ENV="${ADDON_ENV:-}"                    # env this node serves (e.g. dev); protected envs refuse experimental add-ons
  PROTECTED_ENVS="${PROTECTED_ENVS:-prd}"
  ACCEPT_EXPERIMENTAL="${ACCEPT_EXPERIMENTAL:-0}"
  WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
}
load_conf; defaults

stacks_dir() {
  local d
  for d in "${ADDON_STACKS:-}" "$HERE/../../../stacks/addons" "$HERE" "$HERE/stacks" "$ADDONS_DIR/stacks"; do
    [ -n "$d" ] && [ -f "$d/gotenberg/addon.env.example" ] && { (cd "$d" && pwd); return 0; }
  done
  die "add-on templates not found; copy stacks/addons next to this script (see stacks/addons/README.md)"
}
valid_name() { case " $ADDONS " in *" $1 "*) ;; *) CODE=2 die "unknown add-on '$1' (one of: $ADDONS)" ;; esac; }

ADDON_KIND="" ADDON_DEFAULT_ROLE="" ADDON_RAM_MB=0 ADDON_EXPERIMENTAL=0
load_addon() { # pinned defaults, then the conf again so it wins, then what install recorded
  local n="$1"; STACKS="$(stacks_dir)"; ADDON_EXPERIMENTAL=0
  # shellcheck disable=SC1090
  . "$STACKS/$n/addon.env.example"
  load_conf
  ADDON_ROLE="${OPT_ROLE:-${ADDON_ROLE:-$ADDON_DEFAULT_ROLE}}"
  ADDON_NETWORK="${ADDON_NETWORK:-bridge}"; [ "$n" = garage ] || ADDON_NETWORK=bridge
  ADDON_DATA_DIR="${OPT_DATA_DIR:-${ADDON_DATA_DIR:-$ADDONS_DIR/$n}}"
  case "$ADDON_ROLE" in web|db|dedicated) ;; *) CODE=2 die "--role must be web, db or dedicated" ;; esac
  case "$ADDON_NETWORK" in host|bridge) ;; *) CODE=2 die "ADDON_NETWORK must be host or bridge" ;; esac
}
pinned_keys() { grep -oE '^[A-Z0-9_]+=' "$STACKS/$1/addon.env.example" | tr -d =; }
image_of() { local k; k="$(pinned_keys "$1" | grep '_IMAGE$' | head -1 || true)"; [ -z "$k" ] || echo "${!k}"; }
installed() { [ -f "$ADDONS_DIR/$1/stack.env" ]; }
installed_storage() { local n; for n in garage seaweedfs rustfs; do installed "$n" && echo "$n"; done; return 0; }
stack_get() { sed -n "s/^$2=//p" "$ADDONS_DIR/$1/stack.env" 2>/dev/null | tail -1; }
secret_get() { sed -n "s/^$2=//p" "$ADDONS_DIR/$1/secrets.env" 2>/dev/null | tail -1; }

is_private_ip() {
  local ip="$1" a b; [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  [ "$a" = 10 ] || [ "$a" = 127 ] || { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } || { [ "$a" = 192 ] && [ "$b" = 168 ]; }
}
is_loopback() { [[ "$1" == 127.* ]]; }
detect_private_ip() { # DigitalOcean puts the VPC address on eth1
  local ip=""
  command -v ip >/dev/null 2>&1 && ip="$(ip -4 -o addr show dev eth1 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1 || true)"
  echo "$ip"
}
resolve_bind() {
  local b="${OPT_BIND:-${ADDON_BIND:-}}"
  if [ -z "$b" ]; then
    if [ "$ADDON_ROLE" = web ]; then b=127.0.0.1; else b="$(detect_private_ip)"; fi
  fi
  [ -n "$b" ] || die "no private IP found for role $ADDON_ROLE; pass --bind <VPC IP>"
  case "$b" in 0.0.0.0|::|"[::]"|\*) die "refusing to bind $b: add-ons listen on 127.0.0.1 or the private IP only" ;; esac
  is_private_ip "$b" || die "refusing to bind $b: not a private or loopback address (Docker ports bypass ufw)"
  ADDON_BIND="$b"
}

host_mem() { awk -v k="$1" '$1==k":" {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || true; }
ram_report() { # $1 addon; prints findings, never fails
  local total avail est="$ADDON_RAM_MB"; total="$(host_mem MemTotal)"; avail="$(host_mem MemAvailable)"
  [ -n "$total" ] || { echo "  ram      unknown here (no /proc/meminfo); estimate ${est} MB"; return 0; }
  echo "  ram      estimate ${est} MB; host ${total} MB total, ${avail} MB available"
  [ "$((avail - est))" -ge 256 ] || warn "only $((avail - est)) MB would be left; pick a bigger droplet or another role"
  if [ "$ADDON_KIND" = storage ] && [ "$ADDON_ROLE" = web ] && [ "$total" -le 2048 ]; then
    warn "object storage on a ${total} MB web node competes with PHP-FPM; prefer the db node (once MySQL/MariaDB are off) or a dedicated droplet"
  fi
  if [ "$ADDON_ROLE" = db ] && command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'mysql|mariadb' >/dev/null; then
    warn "MySQL/MariaDB still run on this db node; disable them first or size up (docker-db-server-manager.sh engines)"
  fi
}

gates() { # refusals that apply to plan and install
  local n="$1" other
  if [ "$ADDON_KIND" = storage ]; then
    other="$(installed_storage | grep -vx "$n" || true)"
    [ -z "$other" ] || die "object storage '$other' is already installed here; one store per node (remove it first)"
  fi
  if [ "$ADDON_EXPERIMENTAL" = 1 ]; then
    case " $PROTECTED_ENVS " in *" ${ADDON_ENV:-none} "*) die "$n is experimental and refused on protected env '$ADDON_ENV'" ;; esac
    [ "$ACCEPT_EXPERIMENTAL" = 1 ] || die "$n is EXPERIMENTAL (dev/test only); re-run with --accept-experimental"
  fi
  if [ "$n" = rustfs ]; then
    local ak="${RUSTFS_ACCESS_KEY:-$(secret_get rustfs RUSTFS_ACCESS_KEY)}" sk="${RUSTFS_SECRET_KEY:-$(secret_get rustfs RUSTFS_SECRET_KEY)}"
    case "$ak:$sk" in rustfsadmin:*|*:rustfsadmin|minioadmin:*|*:minioadmin|admin:*) die "refusing RustFS default credentials; delete them and let addon.sh generate new ones" ;; esac
  fi
  return 0
}

stack_env() { # non-secret settings recorded for compose and later commands
  local k
  printf '# written by addon.sh %s - non-secret settings for %s (secrets are in secrets.env)\n' "$VERSION" "$1"
  printf 'ADDON_NAME=%s\nADDON_ROLE=%s\nADDON_BIND=%s\nADDON_NETWORK=%s\nADDON_DATA_DIR=%s\nSTORAGE_BUCKET=%s\n' \
    "$1" "$ADDON_ROLE" "$ADDON_BIND" "$ADDON_NETWORK" "$ADDON_DATA_DIR" "$STORAGE_BUCKET"
  for k in $(pinned_keys "$1"); do case "$k" in ADDON_*) ;; *) printf '%s=%s\n' "$k" "${!k}" ;; esac; done
  case "$1" in
    gotenberg) printf 'GOTENBERG_BASIC_AUTH_ON=%s\n' "$(gotenberg_auth_on && echo true || echo false)" ;;
    seaweedfs) [ "${SEAWEED_ADMIN_UI:-1}" = 1 ] && printf 'COMPOSE_PROFILES=admin\n' ;;
  esac
  return 0
}
gotenberg_auth_on() { case "${GOTENBERG_BASIC_AUTH:-auto}" in true|1) return 0 ;; false|0) return 1 ;; esac; ! is_loopback "$ADDON_BIND"; }
secret_spec() { # KEY:value-kind
  case "$1" in
    gotenberg) echo "GOTENBERG_USERNAME:user GOTENBERG_PASSWORD:hex24" ;;
    garage) echo "GARAGE_RPC_SECRET:hex32 GARAGE_ADMIN_TOKEN:hex32 GARAGE_METRICS_TOKEN:hex32 GARAGE_APP_KEY_ID:gk GARAGE_APP_SECRET:hex32" ;;
    seaweedfs) echo "SEAWEED_ADMIN_KEY_ID:ak SEAWEED_ADMIN_SECRET:hex24 SEAWEED_APP_KEY_ID:ak SEAWEED_APP_SECRET:hex24 SEAWEED_ADMIN_PASSWORD:hex16" ;;
    rustfs) echo "RUSTFS_ACCESS_KEY:ak RUSTFS_SECRET_KEY:hex24" ;;
  esac
}
gen_value() {
  case "$1" in user) echo vsw ;; gk) echo "GK$(hex 12)" ;; ak) echo "VSW$(hex 8 | tr a-f A-F)" ;; hex*) hex "${1#hex}" ;; esac
}
write_secrets() { # adds missing keys only; existing credentials are never rotated silently
  local n="$1" f="$ADDONS_DIR/$1/secrets.env" spec k
  (umask 077; [ -f "$f" ] || printf '# addon.sh secrets for %s - chmod 600, never commit, never paste\n' "$n" > "$f")
  chmod 600 "$f"
  for spec in $(secret_spec "$n"); do
    k="${spec%%:*}"; grep -q "^$k=" "$f" || printf '%s=%s\n' "$k" "$(gen_value "${spec#*:}")" >> "$f"
  done
}
garage_toml() { # $1 = file
  # host mode: bind the configured ports on ADDON_BIND; bridge mode: fixed ports inside the container
  local inner="$ADDON_BIND" admin_bind=127.0.0.1 s3p="$GARAGE_S3_PORT" rpcp="$GARAGE_RPC_PORT" admp="$GARAGE_ADMIN_PORT"
  [ "$ADDON_NETWORK" = bridge ] && { inner=0.0.0.0; admin_bind=0.0.0.0; s3p=3900; rpcp=3901; admp=3903; }
  (umask 077; cat > "$1" <<TOML
# written by addon.sh $VERSION - chmod 600 (holds rpc_secret and admin tokens)
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "${GARAGE_DB_ENGINE}"
metadata_auto_snapshot_interval = "6h"
replication_factor = 1
rpc_bind_addr = "${inner}:${rpcp}"
rpc_public_addr = "127.0.0.1:${rpcp}"
rpc_secret = "$(secret_get garage GARAGE_RPC_SECRET)"

[s3_api]
s3_region = "${STORAGE_REGION}"
api_bind_addr = "${inner}:${s3p}"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "${admin_bind}:${admp}"
admin_token = "$(secret_get garage GARAGE_ADMIN_TOKEN)"
metrics_token = "$(secret_get garage GARAGE_METRICS_TOKEN)"
TOML
  )
  [ "$ADDON_NETWORK" = host ] && [ "$ADDON_BIND" != 127.0.0.1 ] && sed -i.tmp "s/^rpc_public_addr = .*/rpc_public_addr = \"${ADDON_BIND}:${GARAGE_RPC_PORT}\"/" "$1" && rm -f "$1.tmp"
  chmod 600 "$1"
}
seaweed_s3_json() {
  local b="$STORAGE_BUCKET"
  (umask 077; cat > "$1" <<JSON
{
  "identities": [
    {"name": "vsw-admin", "credentials": [{"accessKey": "$(secret_get seaweedfs SEAWEED_ADMIN_KEY_ID)", "secretKey": "$(secret_get seaweedfs SEAWEED_ADMIN_SECRET)"}],
     "actions": ["Admin", "Read", "Write", "List", "Tagging"]},
    {"name": "vsw-app", "credentials": [{"accessKey": "$(secret_get seaweedfs SEAWEED_APP_KEY_ID)", "secretKey": "$(secret_get seaweedfs SEAWEED_APP_SECRET)"}],
     "actions": ["Read:$b", "Write:$b", "List:$b", "Tagging:$b"]}
  ]
}
JSON
  )
  chmod 600 "$1"
}

config_sha() { # hash of mounted config files (not of secrets.env; compose already sees those values)
  local f out=""
  for f in garage.toml s3.json; do [ -f "$ADDONS_DIR/$1/$f" ] && out="$out$( (sha256sum "$ADDONS_DIR/$1/$f" 2>/dev/null || shasum -a 256 "$ADDONS_DIR/$1/$f") | cut -c1-16)"; done
  echo "${out:-none}"
}
dca() { local n="$1"; shift; (cd "$ADDONS_DIR/$n" && docker compose --env-file stack.env --env-file secrets.env "$@"); }
need_docker() { { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; } || die "docker with the compose plugin is required"; }
need_root() { [ "$(id -u)" -eq 0 ] || [ "${ADDON_ALLOW_NONROOT:-0}" = 1 ] || die "run as root (sudo)"; }
audit() { printf '%s user=%s addon=%s %s\n' "$(date -u +%FT%TZ)" "${SUDO_USER:-$(id -un)}" "$1" "${*:2}" >> "$AUDIT_LOG" 2>/dev/null || warn "cannot write audit log $AUDIT_LOG"; }
LOCKED=""
lock() {
  mkdir -p "$ADDONS_DIR"; chmod 700 "$ADDONS_DIR"
  mkdir "$ADDONS_DIR/.lock" 2>/dev/null || die "another addon.sh run holds $ADDONS_DIR/.lock (remove it if no run is active)"
  LOCKED="$ADDONS_DIR/.lock"; trap '[ -n "$LOCKED" ] && rmdir "$LOCKED" 2>/dev/null; true' EXIT
}
confirm() { # $1 = word to type
  [ "${OPT_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || die "refusing without a terminal; re-run with --yes"
  local a; read -r -p "Type $1 to continue: " a; [ "$a" = "$1" ] || die "aborted"
}

ports_of() {
  case "$1" in
    gotenberg) echo "$ADDON_BIND:$GOTENBERG_PORT (API)" ;;
    garage) if [ "$ADDON_NETWORK" = host ]; then echo "$ADDON_BIND:$GARAGE_S3_PORT (S3), $ADDON_BIND:$GARAGE_RPC_PORT (RPC, rpc_secret), 127.0.0.1:$GARAGE_ADMIN_PORT (admin)"
            else echo "$ADDON_BIND:$GARAGE_S3_PORT (S3), 127.0.0.1:$GARAGE_ADMIN_PORT (admin); RPC stays inside the container"; fi ;;
    seaweedfs) echo "$ADDON_BIND:$SEAWEED_S3_PORT (S3), 127.0.0.1:$SEAWEED_ADMIN_PORT (admin UI)" ;;
    rustfs) echo "$ADDON_BIND:$RUSTFS_PORT (S3), 127.0.0.1:$RUSTFS_CONSOLE_PORT (console)" ;;
  esac
}
cmd_plan() { # prints the plan; returns 0 when install may proceed
  local n="$1" tmp; load_addon "$n"; resolve_bind; gates "$n"
  echo "plan: $n ($ADDON_KIND$( [ "$ADDON_EXPERIMENTAL" = 1 ] && echo ', EXPERIMENTAL'))"
  echo "  role     $ADDON_ROLE   network $ADDON_NETWORK"
  echo "  image    $(image_of "$n")"
  echo "  listens  $(ports_of "$n")"
  echo "  data     $ADDON_DATA_DIR$( [[ "$ADDON_DATA_DIR" == /mnt/* ]] && echo ' (DO volume)')"
  echo "  files    $ADDONS_DIR/$n/{docker-compose.yml,stack.env,secrets.env (600)$( [ "$n" = garage ] && echo ',garage.toml (600)')$( [ "$n" = seaweedfs ] && echo ',s3.json (600)')}"
  echo "  secrets  generated if missing: $(secret_spec "$n" | tr ' ' '\n' | cut -d: -f1 | tr '\n' ' ')(values never shown)"
  [ "$ADDON_KIND" = storage ] && echo "  bucket   $STORAGE_BUCKET with a key limited to it (read/write, not owner)"
  [ "$n" = gotenberg ] && echo "  auth     basic auth $(gotenberg_auth_on && echo on || echo 'off (loopback only)'); private-IP fetches denied: $GOTENBERG_DENY_PRIVATE_IPS"
  ram_report "$n"
  if [[ "$ADDON_DATA_DIR" == /mnt/* ]] && command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$(echo "$ADDON_DATA_DIR" | cut -d/ -f1-3)" || warn "$(echo "$ADDON_DATA_DIR" | cut -d/ -f1-3) is not mounted; attach the DO volume first"
  fi
  if installed "$n"; then
    tmp="$(mktemp)"; stack_env "$n" > "$tmp"
    if diff -u <(grep -v '^ADDON_CONFIG_SHA=' "$ADDONS_DIR/$n/stack.env") "$tmp" > "$tmp.diff"; then echo "  change   none (already installed with these settings)"
    else echo "  change   stack.env:"; sed 's/^/    /' "$tmp.diff" | tail -n +3; fi
    rm -f "$tmp" "$tmp.diff"
  else echo "  change   new install"; fi
}

copy_templates() {
  local n="$1" d="$ADDONS_DIR/$1"
  mkdir -p "$d"; chmod 700 "$d"
  cp "$STACKS/$n/docker-compose.yml" "$d/docker-compose.yml"
  if [ "$n" = garage ] && [ "$ADDON_NETWORK" = bridge ]; then cp "$STACKS/$n/compose.bridge.yml" "$d/docker-compose.override.yml"
  else rm -f "$d/docker-compose.override.yml"; fi
  if [ "$STACKS" != "$ADDONS_DIR/stacks" ]; then   # keep a copy so later runs work without the repo
    rm -rf "$ADDONS_DIR/stacks.new"; cp -R "$STACKS" "$ADDONS_DIR/stacks.new"
    rm -rf "$ADDONS_DIR/stacks"; mv "$ADDONS_DIR/stacks.new" "$ADDONS_DIR/stacks"
    [ "$SELF" = "$ADDONS_DIR/addon.sh" ] || install -m 700 "$SELF" "$ADDONS_DIR/addon.sh"
  fi
}
data_dirs() {
  local n="$1"
  case "$n" in
    garage) mkdir -p "$ADDON_DATA_DIR/meta" "$ADDON_DATA_DIR/data" ;;
    seaweedfs|rustfs) mkdir -p "$ADDON_DATA_DIR/data" ;;
    *) return 0 ;;
  esac
  chmod 700 "$ADDON_DATA_DIR"
  [ "$n" = rustfs ] && [ "$(id -u)" -eq 0 ] && chown -R 10001:10001 "$ADDON_DATA_DIR/data"
  return 0
}
cmd_install() {
  local n="$1" first=1; need_root; need_docker
  cmd_plan "$n"; installed "$n" && first=0
  confirm "$n"; lock; audit "$n" "install start role=$ADDON_ROLE bind=$ADDON_BIND image=$(image_of "$n")"
  copy_templates "$n"; write_secrets "$n"; gates "$n"; data_dirs "$n"
  case "$n" in garage) garage_toml "$ADDONS_DIR/$n/garage.toml" ;; seaweedfs) seaweed_s3_json "$ADDONS_DIR/$n/s3.json" ;; esac
  stack_env "$n" > "$ADDONS_DIR/$n/stack.env.new"
  printf 'ADDON_CONFIG_SHA=%s\n' "$(config_sha "$n")" >> "$ADDONS_DIR/$n/stack.env.new"   # a changed config recreates the container
  chmod 600 "$ADDONS_DIR/$n/stack.env.new"; mv "$ADDONS_DIR/$n/stack.env.new" "$ADDONS_DIR/$n/stack.env"
  log "starting $n"
  if ! dca "$n" up -d --wait --wait-timeout "$WAIT_TIMEOUT"; then
    dca "$n" logs --tail 40 >&2 || true
    [ "$first" = 1 ] && { dca "$n" down >/dev/null 2>&1 || true; warn "first install failed; containers removed, files kept in $ADDONS_DIR/$n"; }
    audit "$n" "install FAILED"; die "$n did not become healthy"
  fi
  case "$n" in garage) garage_setup ;; seaweedfs) seaweed_setup ;; rustfs) rustfs_setup ;; esac
  audit "$n" "install ok"
  log "$n is up on $(ports_of "$n")"
  echo "next: $ADDONS_DIR/addon.sh doctor $n"
  echo "      $ADDONS_DIR/addon.sh laravel-env $n --out /root/$n.laravel.env   # then merge into the app .env"
}

g() { dca garage exec -T -e RUST_LOG=warn garage /garage "$@"; }
garage_setup() {
  local ver id key="vsw-app-$STORAGE_BUCKET"
  for _ in $(seq 1 30); do g status >/dev/null 2>&1 && break; sleep 2; done
  if g status 2>/dev/null | grep 'NO ROLE ASSIGNED' >/dev/null; then
    id="$(g node id -q 2>/dev/null | head -1 | cut -d@ -f1)"; [ -n "$id" ] || die "garage: no node id"
    ver="$(g layout show 2>/dev/null | sed -n 's/.*[Cc]urrent cluster layout version: *\([0-9]*\).*/\1/p' | head -1)"
    log "garage: layout zone=$GARAGE_ZONE capacity=$GARAGE_CAPACITY version $(( ${ver:-0} + 1 ))"
    g layout assign -z "$GARAGE_ZONE" -c "$GARAGE_CAPACITY" "${id:0:16}" >/dev/null
    g layout apply --version "$(( ${ver:-0} + 1 ))" >/dev/null
  fi
  g bucket info "$STORAGE_BUCKET" >/dev/null 2>&1 || { log "garage: bucket $STORAGE_BUCKET"; g bucket create "$STORAGE_BUCKET" >/dev/null; }
  if ! g key info "$key" >/dev/null 2>&1; then
    log "garage: app key $key (read/write on $STORAGE_BUCKET only)"
    g key import --yes -n "$key" "$(secret_get garage GARAGE_APP_KEY_ID)" "$(secret_get garage GARAGE_APP_SECRET)" >/dev/null
  fi
  g bucket allow --read --write "$STORAGE_BUCKET" --key "$key" >/dev/null
}
sw_shell() { dca seaweedfs exec -T seaweedfs weed shell -master=127.0.0.1:9333 -filer=127.0.0.1:8888; }
seaweed_setup() {
  for _ in $(seq 1 30); do echo "s3.bucket.list" | sw_shell >/dev/null 2>&1 && break; sleep 2; done
  if ! echo "s3.bucket.list" | sw_shell 2>/dev/null | grep -E "(^|[[:space:]])$STORAGE_BUCKET([[:space:]]|$)" >/dev/null; then
    log "seaweedfs: bucket $STORAGE_BUCKET"; echo "s3.bucket.create -name $STORAGE_BUCKET" | sw_shell >/dev/null
  fi
  log "seaweedfs: app identity vsw-app limited to $STORAGE_BUCKET (s3.json)"
}
rustfs_setup() {
  local code
  code="$(printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:%s:s3"\n' "$(secret_get rustfs RUSTFS_ACCESS_KEY)" "$(secret_get rustfs RUSTFS_SECRET_KEY)" "$STORAGE_REGION" \
    | dca rustfs exec -T rustfs curl -s -o /dev/null -w '%{http_code}' -K - -X PUT "http://127.0.0.1:9000/$STORAGE_BUCKET" || true)"
  case "$code" in 200|409) log "rustfs: bucket $STORAGE_BUCKET" ;; *) warn "rustfs: bucket create returned HTTP $code" ;; esac
  warn "rustfs: create a key limited to $STORAGE_BUCKET in the console (ssh -L $RUSTFS_CONSOLE_PORT:127.0.0.1:$RUSTFS_CONSOLE_PORT <host>); the root key is not for the app"
}

recorded() { # load what install recorded for an installed add-on
  local n="$1"; installed "$n" || die "$n is not installed here"
  load_addon "$n"; set -a
  # shellcheck disable=SC1090
  . "$ADDONS_DIR/$n/stack.env"; set +a
}
endpoint_host() { if [ "$ADDON_ROLE" = web ]; then echo 127.0.0.1; else echo "$ADDON_BIND"; fi; }
cmd_laravel_env() {
  local n="$1" out="${OPT_OUT:-}" h keys; recorded "$n"; h="$(endpoint_host)"
  out="${out:-$ADDONS_DIR/$n/laravel.env}"
  [ -e "$out" ] && cp -p "$out" "$out.bak.$(date +%Y%m%d%H%M%S)"
  ( umask 077
    echo "# Laravel keys for $n (from addon.sh $VERSION). Merge into the app .env; keep chmod 600."
    case "$n" in
      gotenberg) echo "GOTENBERG_URL=http://$h:$GOTENBERG_PORT"
        if [ "$GOTENBERG_BASIC_AUTH_ON" = true ]; then
          echo "GOTENBERG_USERNAME=$(secret_get gotenberg GOTENBERG_USERNAME)"; echo "GOTENBERG_PASSWORD=$(secret_get gotenberg GOTENBERG_PASSWORD)"; fi ;;
      garage|seaweedfs|rustfs)
        local port id sec
        case "$n" in
          garage) port="$GARAGE_S3_PORT"; id="$(secret_get garage GARAGE_APP_KEY_ID)"; sec="$(secret_get garage GARAGE_APP_SECRET)" ;;
          seaweedfs) port="$SEAWEED_S3_PORT"; id="$(secret_get seaweedfs SEAWEED_APP_KEY_ID)"; sec="$(secret_get seaweedfs SEAWEED_APP_SECRET)" ;;
          rustfs) port="$RUSTFS_PORT"; id=""; sec=""
            echo "# RustFS: paste a bucket-scoped key created in the console; the root key is deliberately not written here" ;;
        esac
        echo "FILESYSTEM_DISK=s3"; echo "AWS_ACCESS_KEY_ID=$id"; echo "AWS_SECRET_ACCESS_KEY=$sec"
        echo "AWS_DEFAULT_REGION=$STORAGE_REGION"; echo "AWS_BUCKET=$STORAGE_BUCKET"
        echo "AWS_ENDPOINT=http://$h:$port"; echo "AWS_USE_PATH_STYLE_ENDPOINT=true"
        echo "# AWS_URL=  set only if files are served publicly through a proxy/CDN" ;;
    esac ) > "$out.new"
  chmod 600 "$out.new"; mv "$out.new" "$out"
  keys="$(grep -oE '^[A-Z_]+=' "$out" | tr -d = | tr '\n' ' ')"
  audit "$n" "laravel-env written to $out"
  echo "wrote $out (chmod 600): ${keys}(values not shown)"
}

D_BAD=0 D_WARN=0
ok()  { echo "  ok    $*"; }
dwarn() { echo "  warn  $*"; D_WARN=$((D_WARN + 1)); }
bad() { echo "  BAD   $*"; D_BAD=$((D_BAD + 1)); }
container_of() { dca "$1" ps -q "$2" 2>/dev/null | head -1; }
doctor_one() {
  local n="$1" c img pin st hostips ip f
  echo "doctor: $n"; recorded "$n"
  for f in secrets.env stack.env garage.toml s3.json; do
    [ -f "$ADDONS_DIR/$n/$f" ] || continue
    [ "$(perm "$ADDONS_DIR/$n/$f")" = 600 ] && ok "$f is 600" || bad "$f is $(perm "$ADDONS_DIR/$n/$f"); chmod 600 it"
  done
  pin="$(image_of "$n")"
  case "$pin" in *:latest|*:*) [[ "$pin" == *:latest ]] && bad "image $pin is not pinned" || ok "image pinned: $pin" ;; *) bad "image $pin has no tag" ;; esac
  [ "$ADDON_EXPERIMENTAL" = 1 ] && dwarn "$n is experimental: dev/test only"
  c="$(container_of "$n" "$([ "$n" = gotenberg ] && echo gotenberg || echo "$n")")"
  if [ -z "$c" ]; then bad "container not running (start: $ADDONS_DIR/addon.sh install $n)"; return 0; fi
  img="$(docker inspect -f '{{.Config.Image}}' "$c")"
  [ "$img" = "$pin" ] && ok "running $img" || bad "running $img but pinned $pin (re-run install)"
  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c")"
  [ "$st" = healthy ] && ok "health: healthy" || bad "health: $st (logs: docker logs --tail 50 $c)"
  if [ "$ADDON_NETWORK" = bridge ]; then
    hostips="$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}} {{end}}{{end}}' "$c")"
    local exposed=0
    for ip in $hostips; do
      case "$ip" in "$ADDON_BIND"|127.0.0.1) ;; *) bad "published on '${ip:-all interfaces}' (expected $ADDON_BIND or 127.0.0.1)"; exposed=1 ;; esac
    done
    [ -z "$hostips" ] && dwarn "no published ports found"
    [ -n "$hostips" ] && [ "$exposed" = 0 ] && ok "published only on: $(echo "$hostips" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  elif command -v ss >/dev/null 2>&1; then
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ":(${GARAGE_S3_PORT}|${GARAGE_RPC_PORT}|${GARAGE_ADMIN_PORT})$" | grep -E '^(0\.0\.0\.0|\*|\[::\]):' >/dev/null; then
      bad "garage listens on all interfaces; check garage.toml bind addresses"
    else ok "garage listens on $ADDON_BIND / 127.0.0.1 only"; fi
  else dwarn "ss not available; listening addresses not checked"; fi
  case "$n" in
    gotenberg)
      if ! is_loopback "$ADDON_BIND" && [ "$GOTENBERG_BASIC_AUTH_ON" != true ]; then bad "bound to $ADDON_BIND without basic auth"; fi
      [ "$GOTENBERG_DENY_PRIVATE_IPS" = true ] && ok "SSRF guard on (private IPs denied)" || dwarn "GOTENBERG_DENY_PRIVATE_IPS is off: rendered HTML can reach internal services" ;;
    garage)
      g status 2>/dev/null | grep 'NO ROLE ASSIGNED' >/dev/null && bad "layout not applied (re-run install)" || ok "layout applied"
      if g bucket info "$STORAGE_BUCKET" 2>/dev/null | grep "vsw-app-$STORAGE_BUCKET" >/dev/null; then ok "bucket $STORAGE_BUCKET has key vsw-app-$STORAGE_BUCKET"
      else bad "bucket $STORAGE_BUCKET or its app key is missing (re-run install)"; fi ;;
    seaweedfs|rustfs)
      local port code; port="$([ "$n" = seaweedfs ] && echo "$SEAWEED_S3_PORT" || echo "$RUSTFS_PORT")"
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ADDON_BIND:$port/$STORAGE_BUCKET" || true)"
      case "$code" in 401|403) ok "anonymous S3 access denied ($code)" ;; 000) dwarn "S3 port not reachable from here" ;; *) bad "anonymous S3 request returned $code (auth not enforced?)" ;; esac ;;
  esac
  if [ "$ADDON_KIND" = storage ] && [ -d "$ADDON_DATA_DIR" ]; then
    local use; use="$(df -P "$ADDON_DATA_DIR" | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [ "${use:-0}" -ge 95 ]; then bad "data disk ${use}% full"; elif [ "${use:-0}" -ge 85 ]; then dwarn "data disk ${use}% full"; else ok "data disk ${use}% used"; fi
    [ "$ADDON_ROLE" = web ] && dwarn "storage on the web node: backups of the app droplet now include object data; prefer db/dedicated"
    dwarn "back up object data off this droplet (see stacks/addons/README.md#backups)"
  fi
  local avail; avail="$(host_mem MemAvailable)"
  [ -z "$avail" ] || { [ "$avail" -ge 200 ] && ok "memory available: ${avail} MB" || dwarn "memory available: ${avail} MB"; }
}
cmd_doctor() {
  local n list="${1:-}"
  [ -n "$list" ] || list="$(for n in $ADDONS; do installed "$n" && echo "$n"; done; true)"
  [ -n "$list" ] || { echo "no add-ons installed in $ADDONS_DIR"; return 0; }
  for n in $list; do doctor_one "$n"; done
  echo "doctor: $D_BAD problem(s), $D_WARN warning(s)"
  [ "$D_BAD" -eq 0 ]
}
cmd_status() {
  local n any=0
  for n in ${1:-$ADDONS}; do installed "$n" || continue; any=1; echo "== $n ($(stack_get "$n" ADDON_ROLE) on $(stack_get "$n" ADDON_BIND))"; dca "$n" ps; done
  [ "$any" = 1 ] || echo "no add-ons installed in $ADDONS_DIR"
}
cmd_list() {
  local n; printf '%-10s %-8s %-10s %-34s %s\n' NAME KIND ROLE IMAGE INSTALLED
  for n in $ADDONS; do
    ( load_addon "$n"
      printf '%-10s %-8s %-10s %-34s %s\n' "$n" "$ADDON_KIND$([ "$ADDON_EXPERIMENTAL" = 1 ] && echo '*')" "$ADDON_DEFAULT_ROLE" "$(image_of "$n")" \
        "$(installed "$n" && echo "yes ($(stack_get "$n" ADDON_ROLE) on $(stack_get "$n" ADDON_BIND))" || echo no)" )
  done
  echo "* experimental (dev/test only). One object store per node; DO Spaces is the managed alternative."
}
cmd_remove() {
  local n="$1" ts; need_root; need_docker; recorded "$n"
  echo "remove: $n ($ADDON_ROLE on $ADDON_BIND); data $( [ "${OPT_DELETE_DATA:-0}" = 1 ] && echo "WILL BE DELETED: $ADDON_DATA_DIR" || echo "kept in $ADDON_DATA_DIR")"
  confirm "$n"
  if [ "${OPT_DELETE_DATA:-0}" = 1 ]; then
    [ -t 0 ] || [ "${OPT_FORCE:-0}" = 1 ] || die "--delete-data needs a terminal or --force"
    [ "${OPT_FORCE:-0}" = 1 ] || { local a; read -r -p "Type 'delete $n data' to erase $ADDON_DATA_DIR: " a; [ "$a" = "delete $n data" ] || die "aborted"; }
  fi
  lock; dca "$n" --profile admin down --remove-orphans
  ts="$(date +%Y%m%d%H%M%S)"
  if [ "${OPT_DELETE_DATA:-0}" = 1 ]; then
    case "$ADDON_DATA_DIR" in ""|/|/opt|/mnt|/var|/root|/home) die "refusing to delete '$ADDON_DATA_DIR'" ;; esac
    rm -rf "$ADDON_DATA_DIR"; [ "$ADDON_DATA_DIR" = "$ADDONS_DIR/$n" ] || rm -rf "${ADDONS_DIR:?}/$n"
    audit "$n" "removed with data"
  else
    mv "$ADDONS_DIR/$n" "$ADDONS_DIR/.removed-$n-$ts"; audit "$n" "removed; files kept in $ADDONS_DIR/.removed-$n-$ts"
    echo "files and credentials kept in $ADDONS_DIR/.removed-$n-$ts (600)"
  fi
  log "$n removed"
}

main() {
  local cmd="${1:-}" name="" ; [ $# -gt 0 ] && shift
  OPT_ROLE="" OPT_BIND="" OPT_DATA_DIR="" OPT_OUT="" OPT_YES=0 OPT_FORCE=0 OPT_DELETE_DATA=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) OPT_ROLE="${2:?--role needs a value}"; shift ;;
      --bind) OPT_BIND="${2:?--bind needs a value}"; shift ;;
      --data-dir) OPT_DATA_DIR="${2:?--data-dir needs a value}"; shift ;;
      --out) OPT_OUT="${2:?--out needs a value}"; shift ;;
      --yes|-y) OPT_YES=1 ;;
      --force) OPT_FORCE=1 ;;
      --delete-data) OPT_DELETE_DATA=1 ;;
      --accept-experimental) ACCEPT_EXPERIMENTAL=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) CODE=2 die "unknown flag $1" ;;
      *) [ -z "$name" ] || CODE=2 die "one add-on at a time"; name="$1" ;;
    esac; shift
  done
  [ -z "$name" ] || valid_name "$name"
  case "$cmd" in
    list) cmd_list ;;
    plan) [ -n "$name" ] || CODE=2 die "usage: addon.sh plan <name>"; cmd_plan "$name" ;;
    install) [ -n "$name" ] || CODE=2 die "usage: addon.sh install <name>"; cmd_install "$name" ;;
    status) cmd_status "$name" ;;
    doctor) need_docker; cmd_doctor "$name" ;;
    laravel-env) [ -n "$name" ] || CODE=2 die "usage: addon.sh laravel-env <name>"; cmd_laravel_env "$name" ;;
    remove) [ -n "$name" ] || CODE=2 die "usage: addon.sh remove <name>"; cmd_remove "$name" ;;
    version|--version) echo "addon.sh $VERSION" ;;
    ""|-h|--help|help) usage ;;
    *) CODE=2 die "unknown command '$cmd' (see --help)" ;;
  esac
}
[ "${ADDON_SOURCE_ONLY:-0}" = 1 ] || main "$@"
