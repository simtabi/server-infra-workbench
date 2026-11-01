#!/usr/bin/env bash
# monitor.sh - monitoring on ONE node: Beszel, Uptime Kuma, Netdata and/or Prometheus + Grafana + exporters.
# Runs as root ON the node. Which stacks: MONITOR_STACKS; which side: MONITOR_ROLE (hub | agent | both).
#
#   monitor.sh list                                   stacks, units per role, pinned images, installed?
#   monitor.sh plan    [--role R] [--stacks a,b]      what install would do: units, binds, RAM gate (writes nothing)
#   monitor.sh install [--role R] [--stacks a,b] [--yes]
#                                                     plan, confirm, secrets (600), start, wait healthy, targets
#   monitor.sh targets                                rewrite Prometheus targets + Alertmanager from the conf, reload
#   monitor.sh beszel-register --name N --host H      add a node to the Beszel hub (hub side; API, no UI clicks)
#   monitor.sh beszel-key --out FILE                  the hub's PUBLIC key for agents on other nodes
#   monitor.sh tunnel [--host SSH_HOST]               ssh -L commands for the UIs on this node
#   monitor.sh caddy --domain D                       Caddy site block with basic auth (MONITOR_PUBLIC=1; not on Ploi)
#   monitor.sh status | doctor                        containers; binds, pins, perms, health (doctor exits 1 on a problem)
#   monitor.sh remove <unit> [--delete-data] [--yes]  stop a unit; data kept unless --delete-data (typed name)
#
# Config: /etc/vsw-monitor.conf (or MONITOR_CONF=FILE); keys in config/monitor.conf.example.
# UIs bind loopback only (SSH tunnel); agents/exporters bind the private or WireGuard IP, never 0.0.0.0.
# Secrets are generated into <unit>/secrets.env (600) and never printed or logged.
# shellcheck disable=SC2015  # ok/bad/dwarn/die always return 0 or exit, so A && B || C is safe here
set -euo pipefail

VERSION="1.0.0"
STACKS_ALL="beszel kuma netdata prometheus"
UNITS_ALL="beszel beszel-agent kuma netdata prometheus exporters"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
MONITOR_CONF="${MONITOR_CONF:-/etc/vsw-monitor.conf}"
# shellcheck disable=SC1090  # optional: the repo lib, or a copy next to the installed script
for _p in "$HERE/../lib/progress.sh" "$HERE/progress.sh"; do [ -f "$_p" ] && { . "$_p"; break; }; done
type progress_step >/dev/null 2>&1 || progress_step() { printf '==> %s\n' "$*" >&2; }

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!! WARNING: %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit "${CODE:-1}"; }
# usage: the header comment block (up to the first code line), minus shellcheck directives
usage() { awk 'NR==1{next} !/^#/{exit} /^# shellcheck /{next} {sub(/^# ?/,""); print}' "$SELF"; }
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
owner_uid() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
hex() { openssl rand -hex "$1"; }
csv_words() { printf '%s' "$1" | tr ',' ' '; }

load_conf() { # sourced, so it must be trustworthy
  [ -f "$MONITOR_CONF" ] || return 0
  if [ "$(id -u)" -eq 0 ]; then
    [ "$(owner_uid "$MONITOR_CONF")" = 0 ] || die "$MONITOR_CONF must be owned by root"
    case "$(perm "$MONITOR_CONF")" in *[2367]) die "$MONITOR_CONF is world-writable; chmod 600 it" ;; esac
  fi
  # shellcheck disable=SC1090
  . "$MONITOR_CONF"
}
defaults() {
  MONITOR_STACKS="${MONITOR_STACKS:-beszel,kuma}"
  MONITOR_ROLE="${MONITOR_ROLE:-both}"
  MONITOR_DIR="${MONITOR_DIR:-/opt/vsw-monitor}"
  MONITOR_BIND="${MONITOR_BIND:-127.0.0.1}"
  MONITOR_AGENT_BIND="${MONITOR_AGENT_BIND:-}"
  MONITOR_AGENT_NETWORK="${MONITOR_AGENT_NETWORK:-host}"
  MONITOR_TARGETS="${MONITOR_TARGETS:-}"          # "db=10.10.0.5 web=10.10.0.6" (hub side)
  MONITOR_PG_TARGETS="${MONITOR_PG_TARGETS:-}"    # names from MONITOR_TARGETS that run the DB exporters
  MONITOR_PROBE_URLS="${MONITOR_PROBE_URLS:-}"    # "https://app.example.com/up ..."
  MONITOR_PG="${MONITOR_PG:-auto}"                # agent side: DB exporters (auto = the DB manager runs here)
  MONITOR_DB_NETWORK="${MONITOR_DB_NETWORK:-vsw_db}"
  MONITOR_PG_PASSWORD_FILE="${MONITOR_PG_PASSWORD_FILE:-/etc/vsw-monitor/pg-monitor.pass}"
  MONITOR_TEXTFILE_DIR="${MONITOR_TEXTFILE_DIR:-/var/lib/vsw-monitor/textfile}"
  MONITOR_ALLOW_TIGHT="${MONITOR_ALLOW_TIGHT:-0}"
  MONITOR_DB_NODE="${MONITOR_DB_NODE:-auto}"
  MONITOR_BESZEL_KEY_FILE="${MONITOR_BESZEL_KEY_FILE:-}"
  MONITOR_ALERT_WEBHOOK_FILE="${MONITOR_ALERT_WEBHOOK_FILE:-}"
  MONITOR_ALERT_EMAIL="${MONITOR_ALERT_EMAIL:-}" MONITOR_SMTP_SMARTHOST="${MONITOR_SMTP_SMARTHOST:-}"
  MONITOR_SMTP_FROM="${MONITOR_SMTP_FROM:-}" MONITOR_SMTP_USER="${MONITOR_SMTP_USER:-}"
  MONITOR_SMTP_PASSWORD_FILE="${MONITOR_SMTP_PASSWORD_FILE:-}"
  MONITOR_PUBLIC="${MONITOR_PUBLIC:-0}"
  MONITOR_NODE_NAME="${MONITOR_NODE_NAME:-$(hostname -s 2>/dev/null || echo node)}"
  MONITOR_MEMINFO="${MONITOR_MEMINFO:-/proc/meminfo}"
  AUDIT_LOG="${AUDIT_LOG:-/var/log/vsw-monitor.log}"
  WAIT_TIMEOUT="${WAIT_TIMEOUT:-240}"
}
load_conf; defaults

stacks_dir() {
  local d
  for d in "${MONITOR_STACKS_DIR:-}" "$HERE/../../../stacks/monitor" "$HERE/stacks" "$MONITOR_DIR/stacks"; do
    [ -n "$d" ] && [ -f "$d/beszel/monitor.env.example" ] && { (cd "$d" && pwd); return 0; }
  done
  die "monitor templates not found; copy stacks/monitor next to this script"
}

# ---- validation --------------------------------------------------------------------------------
is_private_ip() {
  local ip="$1" a b; [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  [ "$a" = 10 ] || [ "$a" = 127 ] || { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } \
    || { [ "$a" = 192 ] && [ "$b" = 168 ]; } || { [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }
}
is_loopback() { [[ "$1" == 127.* ]]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }
detect_private_ip() { # DigitalOcean puts the VPC address on eth1; WireGuard on wg0
  local ip="" dev
  if command -v ip >/dev/null 2>&1; then
    for dev in eth1 wg0; do ip="$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"; [ -n "$ip" ] && break; done
  fi
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1 || true)"
  echo "$ip"
}
validate() { # every key the plan depends on; CODE=2 = a configuration error
  local s w n h
  [ "$MONITOR_STACKS" = none ] && MONITOR_STACKS=""
  for s in $(csv_words "$MONITOR_STACKS"); do
    case " $STACKS_ALL " in *" $s "*) ;; *) CODE=2 die "MONITOR_STACKS: unknown stack '$s' (any of: ${STACKS_ALL// /,} or none)" ;; esac
  done
  case "$MONITOR_ROLE" in hub|agent|both) ;; *) CODE=2 die "MONITOR_ROLE must be hub, agent or both (got '$MONITOR_ROLE')" ;; esac
  case "$MONITOR_AGENT_NETWORK" in host|bridge) ;; *) CODE=2 die "MONITOR_AGENT_NETWORK must be host or bridge" ;; esac
  case "$MONITOR_PG" in auto|0|1) ;; *) CODE=2 die "MONITOR_PG must be auto, 0 or 1" ;; esac
  is_loopback "$MONITOR_BIND" || CODE=2 die "MONITOR_BIND must be a loopback address (UIs are reached through an SSH tunnel or the Caddy front); got '$MONITOR_BIND'"
  if needs_agent_bind; then
    [ -n "$MONITOR_AGENT_BIND" ] || MONITOR_AGENT_BIND="$(detect_private_ip)"
    if [ -z "$MONITOR_AGENT_BIND" ]; then
      [ "$MONITOR_ROLE" = both ] || CODE=2 die "no private IP found for the agent side; set MONITOR_AGENT_BIND (VPC or WireGuard IP)"
      MONITOR_AGENT_BIND=127.0.0.1; MONITOR_AGENT_NETWORK=bridge
      warn "no private IP: agents bind 127.0.0.1 in bridge mode (single-node setup)"
    fi
    case "$MONITOR_AGENT_BIND" in 0.0.0.0|::|"[::]"|\*) CODE=2 die "refusing MONITOR_AGENT_BIND=$MONITOR_AGENT_BIND: exporters bind a private IP only" ;; esac
    is_private_ip "$MONITOR_AGENT_BIND" || CODE=2 die "refusing MONITOR_AGENT_BIND=$MONITOR_AGENT_BIND: not private/loopback (Docker ports bypass ufw)"
  fi
  for w in $MONITOR_TARGETS; do
    n="${w%%=*}"; h="${w#*=}"
    [ "$n" != "$w" ] && valid_name "$n" && valid_host "$h" || CODE=2 die "MONITOR_TARGETS entry '$w' must be name=host (name: a-z0-9_-, host: IP or DNS name)"
  done
  for n in $MONITOR_PG_TARGETS; do target_host "$n" >/dev/null || CODE=2 die "MONITOR_PG_TARGETS: '$n' is not a name in MONITOR_TARGETS"; done
  for w in $MONITOR_PROBE_URLS; do [[ "$w" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]\"]*)?$ ]] || CODE=2 die "MONITOR_PROBE_URLS: '$w' is not an http(s) URL"; done
  valid_name "$MONITOR_NODE_NAME" || MONITOR_NODE_NAME="$(printf '%s' "$MONITOR_NODE_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | cut -c1-32)"
  [ -z "$MONITOR_ALERT_EMAIL" ] || [[ "$MONITOR_ALERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] || CODE=2 die "MONITOR_ALERT_EMAIL is not an email address"
  [ -z "$MONITOR_ALERT_EMAIL" ] || [ -n "$MONITOR_SMTP_SMARTHOST" ] || CODE=2 die "MONITOR_ALERT_EMAIL needs MONITOR_SMTP_SMARTHOST (host:port)"
  return 0
}
target_host() { local w; for w in $MONITOR_TARGETS; do [ "${w%%=*}" = "$1" ] && { echo "${w#*=}"; return 0; }; done; return 1; }
side_on() { [ "$MONITOR_ROLE" = both ] || [ "$MONITOR_ROLE" = "$1" ]; }
needs_agent_bind() { local u; for u in $(units); do case "$u" in beszel-agent|exporters) return 0 ;; esac; done; return 1; }
units() { # stack list + role -> units installed on this node
  local s
  for s in $(csv_words "$MONITOR_STACKS"); do
    case "$s" in
      beszel) side_on hub && echo beszel; side_on agent && echo beszel-agent ;;
      kuma) side_on hub && echo kuma ;;
      netdata) echo netdata ;;
      prometheus) side_on hub && echo prometheus; side_on agent && echo exporters ;;
    esac
  done; return 0
}

# ---- unit data ---------------------------------------------------------------------------------
MON_STACK="" MON_SIDE="" MON_RAM_MB=0 MON_HEAVY=0 MON_UI_PORT_KEYS=""
load_unit() { # pinned defaults, then the conf so it wins
  STACKS="$(stacks_dir)"
  # shellcheck disable=SC1090
  . "$STACKS/$1/monitor.env.example"
  load_conf
}
pinned_keys() { grep -oE '^[A-Z0-9_]+=' "$STACKS/$1/monitor.env.example" | tr -d = | grep -v '^MON_'; }
images_of() { local k; for k in $(pinned_keys "$1" | grep '_IMAGE$'); do echo "${!k}"; done; }
installed() { [ -f "$MONITOR_DIR/$1/stack.env" ]; }
udir() { echo "$MONITOR_DIR/$1"; }
pqval() { # a libpq key=value DSN value: single-quoted, with \ and ' escaped
  local v="${1//\\/\\\\}"; v="${v//\'/\\\'}"; printf "'%s'" "$v"
}
secret_get() { sed -n "s/^$2=//p" "$MONITOR_DIR/$1/secrets.env" 2>/dev/null | tail -1; }
pg_on() { # agent side: run the DB exporters?
  case "$MONITOR_PG" in 1) return 0 ;; 0) return 1 ;; esac
  [ -f "$MONITOR_PG_PASSWORD_FILE" ]
}
db_node() {
  case "$MONITOR_DB_NODE" in 1) return 0 ;; 0) return 1 ;; esac
  [ -f /etc/docker-db-server-manager.conf ] && return 0
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Image}}' 2>/dev/null | grep -E '(^|/)(postgres|postgis|mysql|mariadb)' >/dev/null
}
mem() { awk -v k="$1" '$1==k":" {print int($2/1024); exit}' "$MONITOR_MEMINFO" 2>/dev/null || true; }

ram_gate() { # sums the units; prints findings; dies when blocked
  local u est=0 total avail heavy="" blocked=0
  for u in $(units); do ( load_unit "$u"; echo "$u $MON_RAM_MB $MON_HEAVY" ); done > "${TMPDIR:-/tmp}/siw-mon-ram.$$"
  while read -r u r h; do est=$((est + r)); [ "$h" = 1 ] && heavy="$heavy $u"; done < "${TMPDIR:-/tmp}/siw-mon-ram.$$"
  rm -f "${TMPDIR:-/tmp}/siw-mon-ram.$$"
  total="$(mem MemTotal)"; avail="$(mem MemAvailable)"
  if [ -z "$total" ]; then echo "  ram      unknown here (no $MONITOR_MEMINFO); estimate ${est} MB"; return 0; fi
  echo "  ram      estimate ${est} MB; host ${total} MB total, ${avail} MB available"
  if [ -n "$heavy" ] && [ "$total" -le 2048 ] && db_node; then
    if [ "$MONITOR_ALLOW_TIGHT" = 1 ]; then warn "${heavy# } next to a database on a ${total} MB node: allowed by MONITOR_ALLOW_TIGHT=1"
    else blocked=1; echo "  BLOCKED  ${heavy# } next to a database on a ${total} MB node (use beszel,kuma here, a hub elsewhere, or MONITOR_ALLOW_TIGHT=1)"; fi
  fi
  [ "$((avail - est))" -ge 256 ] || { if [ "$((avail - est))" -lt 0 ] && [ "$MONITOR_ALLOW_TIGHT" != 1 ]; then blocked=1
    echo "  BLOCKED  not enough memory: ${avail} MB available, ${est} MB needed"; else warn "only $((avail - est)) MB would be left after monitoring"; fi; }
  [ "$blocked" = 0 ] || CODE=3 die "RAM gate: refusing this plan (see above)"
}

# ---- plan --------------------------------------------------------------------------------------
cmd_plan() {
  local u img
  validate
  echo "monitor plan: role=$MONITOR_ROLE stacks=${MONITOR_STACKS:-none} node=$MONITOR_NODE_NAME"
  # install needs Docker; say so in the plan (a Ploi web server has none: server init installs it for role db only)
  { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; } \
    || echo "  needs    docker with the compose plugin on this node (install refuses without it; on a Ploi web server put the hub on another node)"
  [ -n "$(units)" ] || { echo "  nothing to install (MONITOR_STACKS=none or no unit for role $MONITOR_ROLE)"; return 0; }
  for u in $(units); do
    ( load_unit "$u"
      printf '  unit     %-13s %-6s %4s MB  %s\n' "$u" "$MON_SIDE" "$MON_RAM_MB" "$(images_of "$u" | tr '\n' ' ')"
      for img in $(images_of "$u"); do [[ "$img" == *:* && "$img" != *:latest ]] || die "$u: image '$img' is not pinned to a tag"; done
      case "$u" in
        beszel|kuma|prometheus|netdata) printf '           ui on %s (tunnel)\n' "$MONITOR_BIND" ;;
        beszel-agent|exporters) printf '           listens on %s (%s network)\n' "$MONITOR_AGENT_BIND" "$MONITOR_AGENT_NETWORK" ;;
      esac
      [ "$u" = exporters ] && { pg_on && echo "           + postgres-exporter, pgbouncer-exporter (login vsw_monitor)" || echo "           DB exporters off (no $MONITOR_PG_PASSWORD_FILE; run the DB manager's monitor-user first)"; }
      [ "$u" = beszel-agent ] && ! side_on hub && [ -z "$MONITOR_BESZEL_KEY_FILE" ] && echo "           needs MONITOR_BESZEL_KEY_FILE (hub: monitor.sh beszel-key --out FILE, copy it here)"
      if installed "$u"; then echo "           change: re-render (data kept)"; else echo "           change: new install"; fi )
  done
  if side_on hub && in_units prometheus; then
    echo "  targets  $(local_targets_desc)${MONITOR_TARGETS:+ $MONITOR_TARGETS}"
    [ -n "$MONITOR_PROBE_URLS" ] && echo "  probes   $MONITOR_PROBE_URLS"
    echo "  alerts   $(alert_desc)"
  fi
  side_on agent && [ "$MONITOR_ROLE" = agent ] && fw_hint
  ram_gate
}
# no `units | grep -q`: grep exits at the first match, units gets SIGPIPE, and pipefail turns a hit into a miss
in_units() { local l; l="$(units)"; [[ $'\n'"$l"$'\n' == *$'\n'"$1"$'\n'* ]]; }
local_targets_desc() { if side_on agent && in_units exporters; then echo "$MONITOR_NODE_NAME=local"; else echo "(no local exporters)"; fi; }
alert_desc() {
  local d=""; [ -n "$MONITOR_ALERT_WEBHOOK_FILE" ] && d="webhook"; [ -n "$MONITOR_ALERT_EMAIL" ] && d="${d:+$d + }email $MONITOR_ALERT_EMAIL"
  echo "${d:-none configured (rules still visible in Grafana/Alertmanager)}"
}
fw_hint() {
  echo "  firewall hub -> this node (private network only; Docker-published ports bypass ufw, so the VPC/cloud firewall is the gate):"
  echo "           tcp 45876 (beszel-agent), 9100 (node), 9338 (cadvisor), 9187/9127 (postgres/pgbouncer exporters)"
}

# ---- install -----------------------------------------------------------------------------------
need_root() { [ "$(id -u)" -eq 0 ] || [ "${MONITOR_ALLOW_NONROOT:-0}" = 1 ] || die "run as root (sudo)"; }
need_docker() { { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; } || die "docker with the compose plugin is required"; }
audit() { printf '%s user=%s unit=%s %s\n' "$(date -u +%FT%TZ)" "${SUDO_USER:-$(id -un)}" "$1" "${*:2}" >> "$AUDIT_LOG" 2>/dev/null || warn "cannot write audit log $AUDIT_LOG"; }
confirm() {
  [ "${OPT_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || die "refusing without a terminal; re-run with --yes"
  local a; read -r -p "Type $1 to continue: " a; [ "$a" = "$1" ] || die "aborted"
}
LOCKED=""
lock() {
  mkdir -p "$MONITOR_DIR"; chmod 700 "$MONITOR_DIR"
  mkdir "$MONITOR_DIR/.lock" 2>/dev/null || die "another monitor.sh run holds $MONITOR_DIR/.lock (remove it if no run is active)"
  LOCKED="$MONITOR_DIR/.lock"; trap '[ -n "$LOCKED" ] && rmdir "$LOCKED" 2>/dev/null; true' EXIT
}
dcu() { # compose for an installed unit
  local u="$1" f=(-f docker-compose.yml); shift
  [ -f "$MONITOR_DIR/$u/compose.host.yml" ] && f+=(-f compose.host.yml)
  (cd "$MONITOR_DIR/$u" && docker compose --env-file stack.env --env-file secrets.env "${f[@]}" "$@")
}
write_secrets() { # $1 unit, then KEY:kind ...; adds missing keys only (never rotates silently)
  local u="$1" f spec k; f="$(udir "$u")/secrets.env"; shift
  (umask 077; [ -f "$f" ] || printf '# monitor.sh secrets for %s - chmod 600, never commit, never paste\n' "$u" > "$f")
  chmod 600 "$f"
  for spec in "$@"; do k="${spec%%:*}"; grep -q "^$k=" "$f" || printf '%s=%s\n' "$k" "$(hex "${spec#*:}")" >> "$f"; done
}
set_secret() { # unit KEY VALUE (replaces)
  local f; f="$(udir "$1")/secrets.env"
  (umask 077; { grep -v "^$2=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } > "$f.new"); mv "$f.new" "$f"; chmod 600 "$f"
}
stack_env() { # non-secret settings compose reads
  local u="$1" k
  printf '# written by monitor.sh %s for %s (secrets are in secrets.env)\n' "$VERSION" "$u"
  printf 'MONITOR_BIND=%s\nMONITOR_AGENT_BIND=%s\nMONITOR_TEXTFILE_DIR=%s\nMONITOR_DB_NETWORK=%s\n' \
    "$MONITOR_BIND" "${MONITOR_AGENT_BIND:-127.0.0.1}" "$MONITOR_TEXTFILE_DIR" "$MONITOR_DB_NETWORK"
  for k in $(pinned_keys "$u"); do printf '%s=%s\n' "$k" "${!k}"; done
  local inner; if [ "$MONITOR_AGENT_NETWORK" = host ]; then inner="${MONITOR_AGENT_BIND:-127.0.0.1}"; else inner=0.0.0.0; fi
  case "$u" in
    beszel-agent) printf 'BESZEL_AGENT_LISTEN=%s:%s\n' "$inner" "$BESZEL_AGENT_PORT" ;;
    exporters) printf 'NODE_EXPORTER_LISTEN=%s:%s\n' "$inner" "$( [ "$MONITOR_AGENT_NETWORK" = host ] && echo "$NODE_EXPORTER_PORT" || echo 9100)"
      pg_on && printf 'COMPOSE_PROFILES=postgres\n'
      printf 'MONITOR_PG_HOST=%s\nMONITOR_PGBOUNCER_HOST=%s\nMONITOR_PG_SSLMODE=%s\nMONITOR_PGBOUNCER_SSLMODE=%s\n' \
        "${MONITOR_PG_HOST:-postgres}" "${MONITOR_PGBOUNCER_HOST:-pgbouncer}" "${MONITOR_PG_SSLMODE:-disable}" "${MONITOR_PGBOUNCER_SSLMODE:-disable}" ;;
    netdata) printf 'NETDATA_HOSTNAME=%s\n' "$MONITOR_NODE_NAME" ;;
  esac
  return 0
}
copy_unit() {
  local u="$1" d; d="$(udir "$u")"
  mkdir -p "$d"; chmod 700 "$d"
  cp "$STACKS/$u/docker-compose.yml" "$d/docker-compose.yml"
  if [ -f "$STACKS/$u/compose.host.yml" ] && [ "$MONITOR_AGENT_NETWORK" = host ]; then cp "$STACKS/$u/compose.host.yml" "$d/compose.host.yml"
  else rm -f "$d/compose.host.yml"; fi
  if [ "$u" = prometheus ]; then
    cp "$STACKS/$u/prometheus.yml" "$STACKS/$u/blackbox.yml" "$d/"
    rm -rf "$d/rules" "$d/grafana"; cp -R "$STACKS/$u/rules" "$STACKS/$u/grafana" "$d/"; rm -f "$d/grafana/dashboards.py"
  fi
  if [ "$STACKS" != "$MONITOR_DIR/stacks" ]; then   # keep a copy so later runs work without the repo
    rm -rf "$MONITOR_DIR/stacks.new"; cp -R "$STACKS" "$MONITOR_DIR/stacks.new"
    rm -rf "$MONITOR_DIR/stacks"; mv "$MONITOR_DIR/stacks.new" "$MONITOR_DIR/stacks"
    [ "$SELF" = "$MONITOR_DIR/monitor.sh" ] || install -m 700 "$SELF" "$MONITOR_DIR/monitor.sh"
  fi
}
owned_dir() { # dir uid: data dirs for containers that run as a fixed non-root user
  # root (every real install: need_root) chowns + 700; the 777 branch only runs in the non-root container tests
  mkdir -p "$1"; if [ "$(id -u)" -eq 0 ]; then chown -R "$2" "$1"; chmod 700 "$1"; else chmod 777 "$1"; fi
}
prepare_unit() {
  local u="$1" d; d="$(udir "$u")"
  case "$u" in
    beszel) mkdir -p "$d/data"; write_secrets beszel BESZEL_ADMIN_PASSWORD:24 ;;
    kuma) mkdir -p "$d/data"; write_secrets kuma ;;
    netdata) mkdir -p "$d/lib" "$d/cache"; write_secrets netdata; netdata_conf "$d/netdata.conf" ;;
    beszel-agent) mkdir -p "$d/data"; write_secrets beszel-agent; agent_key "$d/hub.pub" ;;
    exporters) write_secrets exporters; mkdir -p "$MONITOR_TEXTFILE_DIR"; chmod 755 "$MONITOR_TEXTFILE_DIR"
      if pg_on; then [ -r "$MONITOR_PG_PASSWORD_FILE" ] || die "MONITOR_PG=1 but $MONITOR_PG_PASSWORD_FILE is missing (DB manager: monitor-user)"
        local pgpw; pgpw="$(tr -d '\n' < "$MONITOR_PG_PASSWORD_FILE")"
        set_secret exporters MONITOR_PG_PASSWORD "$pgpw"
        # the pgbouncer exporter takes one connection string (lib/pq). Use the libpq key=value form, built
        # here into secrets.env (600): no URL with a password slot anywhere in a tracked file.
        set_secret exporters PGBOUNCER_EXPORTER_CONNECTION_STRING \
          "host=${MONITOR_PGBOUNCER_HOST:-pgbouncer} port=5432 dbname=pgbouncer user=$(pqval "${MONITOR_PG_USER:-vsw_monitor}") password=$(pqval "$pgpw") sslmode=${MONITOR_PGBOUNCER_SSLMODE:-disable}"
        unset pgpw; fi ;;
    prometheus) write_secrets prometheus GRAFANA_ADMIN_PASSWORD:24
      owned_dir "$d/data/prometheus" 65534; owned_dir "$d/data/alertmanager" 65534; owned_dir "$d/data/grafana" 472
      render_targets; render_alertmanager ;;
  esac
}
netdata_conf() {
  local bind; if [ "$MONITOR_AGENT_NETWORK" = host ]; then bind="$MONITOR_BIND"; else bind="*"; fi
  printf '# written by monitor.sh %s\n[global]\n  hostname = %s\n[db]\n  mode = dbengine\n[web]\n  bind to = %s\n[cloud]\n  enabled = no\n' \
    "$VERSION" "$MONITOR_NODE_NAME" "$bind" > "$1"
  chmod 644 "$1"
}
agent_key() { # the hub's PUBLIC key; from MONITOR_BESZEL_KEY_FILE, or the local hub's API
  local f="$1"
  if [ -n "$MONITOR_BESZEL_KEY_FILE" ]; then
    [ -r "$MONITOR_BESZEL_KEY_FILE" ] || die "MONITOR_BESZEL_KEY_FILE $MONITOR_BESZEL_KEY_FILE not readable"
    grep -qE '^ssh-ed25519 [A-Za-z0-9+/=]+' "$MONITOR_BESZEL_KEY_FILE" || die "MONITOR_BESZEL_KEY_FILE does not hold an ssh-ed25519 PUBLIC key"
    grep -E '^ssh-ed25519 ' "$MONITOR_BESZEL_KEY_FILE" | head -1 > "$f"
  elif installed beszel; then beszel_pubkey > "$f"
  else die "beszel-agent needs the hub key: install the beszel hub here first, or set MONITOR_BESZEL_KEY_FILE"; fi
  chmod 644 "$f"
}

# Beszel hub API (PocketBase). Credentials go to curl through stdin, never argv.
BZ_TOKEN="" BZ_UID=""
bz_port() { (load_unit beszel; echo "$BESZEL_PORT"); }
bz_url() { echo "http://$MONITOR_BIND:$(bz_port)"; }
bz_auth() {
  local email pw body; installed beszel || die "the beszel hub is not installed on this node"
  email="$(sed -n 's/^BESZEL_ADMIN_EMAIL=//p' "$(udir beszel)/stack.env")"; pw="$(secret_get beszel BESZEL_ADMIN_PASSWORD)"
  body="$(printf '{"identity":"%s","password":"%s"}' "$email" "$pw" | curl -fsS -m 10 -H 'Content-Type: application/json' --data @- "$(bz_url)/api/collections/users/auth-with-password")" \
    || die "beszel: login failed (is the hub healthy? monitor.sh doctor)"
  BZ_TOKEN="$(printf '%s' "$body" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  BZ_UID="$(printf '%s' "$body" | sed -n 's/.*"record":{[^}]*"id":"\([a-z0-9]*\)".*/\1/p')"
  [ -n "$BZ_TOKEN" ] && [ -n "$BZ_UID" ] || die "beszel: unexpected login response"
}
bz_api() { # method path [json]
  local m="$1" p="$2"
  printf 'header = "Authorization: %s"\n' "$BZ_TOKEN" | curl -fsS -m 10 -K - -X "$m" -H 'Content-Type: application/json' ${3:+--data "$3"} "$(bz_url)$p"
}
beszel_pubkey() {
  local k; bz_auth; k="$(bz_api GET /api/beszel/getkey | sed -n 's/.*"key":"\(ssh-ed25519 [A-Za-z0-9+\/=]*\)[^"]*".*/\1/p')"
  [ -n "$k" ] || die "beszel: could not read the hub public key"
  echo "$k"
}
cmd_beszel_key() {
  local out="${OPT_OUT:-}"; [ -n "$out" ] || CODE=2 die "usage: monitor.sh beszel-key --out FILE"
  validate; beszel_pubkey > "$out.new"; chmod 644 "$out.new"; mv "$out.new" "$out"
  echo "wrote the hub PUBLIC key to $out; copy it to each agent node and set MONITOR_BESZEL_KEY_FILE there"
}
cmd_beszel_register() {
  local name="${OPT_NAME:-}" host="${OPT_HOST:-}" port="${OPT_PORT:-45876}" list
  validate
  valid_name "$name" || CODE=2 die "--name must match [a-z0-9][a-z0-9_-]{0,31}"
  valid_host "$host" || CODE=2 die "--host must be an IP or DNS name"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || CODE=2 die "--port must be a number"
  bz_auth; list="$(bz_api GET "/api/collections/systems/records?perPage=200")"
  if printf '%s' "$list" | grep -F "\"name\":\"$name\"" >/dev/null; then echo "beszel: system $name already registered"; return 0; fi
  bz_api POST /api/collections/systems/records "$(printf '{"name":"%s","host":"%s","port":"%s","users":["%s"]}' "$name" "$host" "$port" "$BZ_UID")" >/dev/null \
    || die "beszel: register failed"
  audit beszel "registered system $name ($host:$port)"
  echo "beszel: registered $name at $host:$port"
}
bz_local_register() { # role both: register this node's own agent
  local h; if [ "$MONITOR_AGENT_NETWORK" = bridge ]; then h=beszel-agent; else h="$MONITOR_AGENT_BIND"; fi
  is_loopback "$h" && h=host.docker.internal
  OPT_NAME="$MONITOR_NODE_NAME" OPT_HOST="$h" OPT_PORT="$( (load_unit beszel-agent; echo "$BESZEL_AGENT_PORT") )" cmd_beszel_register
}

# ---- Prometheus targets + Alertmanager ----------------------------------------------------------
json_targets() { # job -> file_sd JSON from "host:port name" lines on stdin
  local first=1 hp n; printf '['
  while read -r hp n; do [ -n "$hp" ] || continue; [ "$first" = 1 ] || printf ','; first=0
    printf '\n  {"targets": ["%s"], "labels": {"host": "%s"}}' "$hp" "$n"; done
  printf '\n]\n'
}
render_targets() {
  local d t w n h; d="$(udir prometheus)/targets"; mkdir -p "$d"; chmod 755 "$d"
  ( load_unit exporters
    local_on() { side_on agent && in_units exporters; }
    lh() { if [ "$MONITOR_AGENT_NETWORK" = bridge ]; then echo "$1:$2"; else echo "$MONITOR_AGENT_BIND:$3"; fi; }
    { local_on && echo "$(lh node-exporter 9100 "$NODE_EXPORTER_PORT") $MONITOR_NODE_NAME"
      for w in $MONITOR_TARGETS; do echo "${w#*=}:$NODE_EXPORTER_PORT ${w%%=*}"; done; } | json_targets > "$d/node.json.new"
    { local_on && echo "$(lh cadvisor 8080 "$CADVISOR_PORT") $MONITOR_NODE_NAME"
      for w in $MONITOR_TARGETS; do echo "${w#*=}:$CADVISOR_PORT ${w%%=*}"; done; } | json_targets > "$d/cadvisor.json.new"
    { local_on && pg_on && echo "$(lh postgres-exporter 9187 "$POSTGRES_EXPORTER_PORT") $MONITOR_NODE_NAME"
      for n in $MONITOR_PG_TARGETS; do echo "$(target_host "$n"):$POSTGRES_EXPORTER_PORT $n"; done; } | json_targets > "$d/postgres.json.new"
    { local_on && pg_on && echo "$(lh pgbouncer-exporter 9127 "$PGBOUNCER_EXPORTER_PORT") $MONITOR_NODE_NAME"
      for n in $MONITOR_PG_TARGETS; do echo "$(target_host "$n"):$PGBOUNCER_EXPORTER_PORT $n"; done; } | json_targets > "$d/pgbouncer.json.new"
    for t in $MONITOR_PROBE_URLS; do h="${t#*://}"; echo "$t ${h%%[:/]*}"; done | json_targets > "$d/probes.json.new" )
  for t in node cadvisor postgres pgbouncer probes; do chmod 644 "$d/$t.json.new"; mv "$d/$t.json.new" "$d/$t.json"; done
}
render_alertmanager() {
  local d f r="null"; d="$(udir prometheus)"; f="$d/alertmanager.yml"
  mkdir -p "$d/am-secrets"; chmod 700 "$d/am-secrets"; [ "$(id -u)" -eq 0 ] && chown 65534 "$d/am-secrets"
  amsecret() { # name source-file: copy a secret so only the alertmanager user can read it
    [ -r "$2" ] || die "$2 is not readable"
    (umask 077; tr -d '\n' < "$2" > "$d/am-secrets/$1"); [ "$(id -u)" -eq 0 ] && chown 65534 "$d/am-secrets/$1"; chmod 400 "$d/am-secrets/$1"
  }
  { echo "# written by monitor.sh $VERSION from MONITOR_ALERT_* (secrets are files under am-secrets/, 400)"
    echo "route: {receiver: vsw, group_by: [alertname, host], group_wait: 30s, group_interval: 5m, repeat_interval: 4h}"
    [ -n "$MONITOR_ALERT_WEBHOOK_FILE$MONITOR_ALERT_EMAIL" ] && r=vsw
    echo "receivers:"
    echo "  - name: vsw"
    [ "$r" = null ] && echo "    # no MONITOR_ALERT_WEBHOOK_FILE / MONITOR_ALERT_EMAIL: alerts are visible in Alertmanager and Grafana only"
    if [ -n "$MONITOR_ALERT_WEBHOOK_FILE" ]; then amsecret webhook_url "$MONITOR_ALERT_WEBHOOK_FILE"
      echo "    webhook_configs: [{url_file: /etc/alertmanager/secrets/webhook_url, send_resolved: true}]"; fi
    if [ -n "$MONITOR_ALERT_EMAIL" ]; then
      echo "    email_configs:"
      echo "      - to: \"$MONITOR_ALERT_EMAIL\""
      echo "        from: \"${MONITOR_SMTP_FROM:-$MONITOR_ALERT_EMAIL}\""
      echo "        smarthost: \"$MONITOR_SMTP_SMARTHOST\""
      echo "        send_resolved: true"
      [ -n "$MONITOR_SMTP_USER" ] && echo "        auth_username: \"$MONITOR_SMTP_USER\""
      if [ -n "$MONITOR_SMTP_PASSWORD_FILE" ]; then amsecret smtp_password "$MONITOR_SMTP_PASSWORD_FILE"
        echo "        auth_password_file: /etc/alertmanager/secrets/smtp_password"; fi
    fi
  } > "$f.new"
  chmod 644 "$f.new"; mv "$f.new" "$f"
}
cmd_targets() {
  validate; installed prometheus || die "the prometheus hub is not installed on this node"
  ( load_unit prometheus; render_targets; render_alertmanager )
  need_docker; dcu prometheus kill -s HUP prometheus alertmanager >/dev/null 2>&1 || warn "reload signal failed (containers down?)"
  audit prometheus "targets rewritten"; echo "targets and alertmanager.yml rewritten; Prometheus reloads them"
}

cmd_install() {
  local u first; need_root; need_docker
  cmd_plan; [ -n "$(units)" ] || return 0
  confirm monitor; lock
  docker network inspect vsw_monitor >/dev/null 2>&1 || docker network create vsw_monitor >/dev/null
  export PROGRESS_TOTAL PROGRESS_N; PROGRESS_TOTAL="$(units | wc -l | tr -d ' ')"; PROGRESS_N=0
  for u in $(units); do
    progress_step "$u"
    ( load_unit "$u"; first=1; installed "$u" && first=0
      audit "$u" "install start images=$(images_of "$u" | tr '\n' ',')"
      copy_unit "$u"; prepare_unit "$u"
      stack_env "$u" > "$(udir "$u")/stack.env.new"; chmod 600 "$(udir "$u")/stack.env.new"; mv "$(udir "$u")/stack.env.new" "$(udir "$u")/stack.env"
      if ! dcu "$u" up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"; then
        dcu "$u" logs --tail 40 >&2 || true
        [ "$first" = 1 ] && { dcu "$u" down >/dev/null 2>&1 || true; warn "first install of $u failed; containers removed, files kept in $(udir "$u")"; }
        audit "$u" "install FAILED"; die "$u did not become healthy"
      fi
      audit "$u" "install ok" )
  done
  if in_units beszel && in_units beszel-agent; then bz_local_register; fi
  log "monitoring is up on $MONITOR_NODE_NAME ($(units | tr '\n' ' '))"
  echo "next: $MONITOR_DIR/monitor.sh doctor"
  side_on hub && echo "      $MONITOR_DIR/monitor.sh tunnel --host <this-server>   # then open the UIs on your laptop"
  in_units kuma && echo "      Uptime Kuma: create the admin account through the tunnel now (first visitor sets it)"
  in_units beszel && ! in_units beszel-agent && echo "      $MONITOR_DIR/monitor.sh beszel-key --out /root/beszel-hub.pub   # for the agent nodes"
  return 0
}

# ---- tunnel / caddy -----------------------------------------------------------------------------
cmd_tunnel() {
  local u k p args="" desc=""
  for u in beszel kuma netdata prometheus; do installed "$u" || continue
    ( load_unit "$u"; for k in $MON_UI_PORT_KEYS; do echo "$u $k ${!k}"; done ); done > "${TMPDIR:-/tmp}/siw-mon-t.$$"
  while read -r u k p; do args="$args -L $p:$MONITOR_BIND:$p"; desc="$desc\n  http://127.0.0.1:$p  $u ($k)"; done < "${TMPDIR:-/tmp}/siw-mon-t.$$"
  rm -f "${TMPDIR:-/tmp}/siw-mon-t.$$"
  [ -n "$args" ] || { echo "no monitoring UI installed on this node"; return 0; }
  echo "run on your laptop:"; echo "  ssh -N$args ${OPT_HOST:-<user>@<this-server>}"
  printf "then open:%b\n" "$desc"
}
ploi_managed() { [ -d /home/ploi ] || [ -d /etc/ploi ]; }
cmd_caddy() {
  local dom="${OPT_DOMAIN:-}" d hash user=vsw; validate
  [ "$MONITOR_PUBLIC" = 1 ] || CODE=2 die "MONITOR_PUBLIC=1 is required for a public front (the default is the SSH tunnel)"
  ploi_managed && die "refusing on a Ploi server: nginx owns 80/443 there; use the SSH tunnel"
  [[ "$dom" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || CODE=2 die "--domain must be a DNS name (e.g. monitor.example.com)"
  installed prometheus || installed beszel || installed kuma || die "no monitoring UI installed here"
  need_docker; d="$MONITOR_DIR/caddy"; mkdir -p "$d"; chmod 700 "$d"
  write_secrets_dir "$d"
  hash="$(sed -n 's/^MONITOR_PUBLIC_PASSWORD=//p' "$d/secrets.env" | docker run --rm -i "${CADDY_IMAGE:-caddy:2.11}" caddy hash-password 2>/dev/null | tail -1)"
  [[ "$hash" == \$2* ]] || die "could not hash the password with caddy"
  { echo "# written by monitor.sh $VERSION: paste into stacks/caddy/conf/Caddyfile (basic auth; password in $d/secrets.env)"
    echo "$dom {"
    echo "  basic_auth { $user $hash }"
    installed prometheus && echo "  handle_path /grafana/* { reverse_proxy $MONITOR_BIND:$( (load_unit prometheus; echo "$GRAFANA_PORT") ) }"
    installed kuma && echo "  handle_path /kuma/* { reverse_proxy $MONITOR_BIND:$( (load_unit kuma; echo "$KUMA_PORT") ) }"
    installed beszel && echo "  reverse_proxy $MONITOR_BIND:$( (load_unit beszel; echo "$BESZEL_PORT") )"
    echo "}"; } > "$d/monitor.Caddyfile"
  chmod 600 "$d/monitor.Caddyfile"; audit caddy "site block for $dom written"
  echo "wrote $d/monitor.Caddyfile (basic auth user '$user'; password in $d/secrets.env, not shown)"
  echo "note: Grafana/Kuma under a sub-path also need their root URL set; a subdomain per UI is simpler"
}
write_secrets_dir() { (umask 077; [ -f "$1/secrets.env" ] || printf 'MONITOR_PUBLIC_PASSWORD=%s\n' "$(hex 16)" > "$1/secrets.env"); chmod 600 "$1/secrets.env"; }

# ---- status / doctor / remove -------------------------------------------------------------------
D_BAD=0 D_WARN=0
ok()  { echo "  ok    $*"; }
dwarn() { echo "  warn  $*"; D_WARN=$((D_WARN + 1)); }
bad() { echo "  BAD   $*"; D_BAD=$((D_BAD + 1)); }
doctor_unit() {
  local u="$1" d f c ip svc img st hostips; d="$(udir "$u")"; echo "doctor: $u"
  for f in secrets.env stack.env; do [ -f "$d/$f" ] && { [ "$(perm "$d/$f")" = 600 ] && ok "$f is 600" || bad "$f is $(perm "$d/$f"); chmod 600 it"; }; done
  while read -r img; do [[ "$img" == *:* && "$img" != *:latest ]] && ok "pinned $img" || bad "image $img is not pinned"; done < <(sed -n 's/^[A-Z_]*_IMAGE=//p' "$d/stack.env")
  for svc in $(dcu "$u" ps --services 2>/dev/null); do
    c="$(dcu "$u" ps -q "$svc" 2>/dev/null | head -1)"
    [ -n "$c" ] || { bad "$svc not running (monitor.sh install)"; continue; }
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c")"
    case "$st" in healthy|running) ok "$svc: $st" ;; *) bad "$svc: $st (docker logs --tail 50 $c)" ;; esac
    hostips="$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}} {{end}}{{end}}' "$c")"
    for ip in $hostips; do
      case "$ip" in "$MONITOR_BIND"|127.0.0.1) ;; "$(sed -n 's/^MONITOR_AGENT_BIND=//p' "$d/stack.env")") is_private_ip "$ip" || bad "$svc published on public $ip" ;;
        *) bad "$svc published on '${ip:-all interfaces}'" ;; esac
    done
  done
  if [ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$(dcu "$u" ps -q 2>/dev/null | head -1)" 2>/dev/null)" = host ] && command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(45876|9100|19999)$' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' >/dev/null && bad "a host-network monitor port listens on all interfaces" || ok "host-network listeners bound to $MONITOR_BIND / the agent IP only"
  fi
  [ "$u" = prometheus ] && doctor_prometheus
  return 0
}
doctor_prometheus() {
  local p g t up down
  p="$( (load_unit prometheus; echo "$PROMETHEUS_PORT") )"; g="$( (load_unit prometheus; echo "$GRAFANA_PORT") )"
  # fetch once; count without grep, whose "no match" exit would end a set -e/pipefail script
  t="$(curl -fsS -m 5 "http://$MONITOR_BIND:$p/api/v1/targets?state=active" 2>/dev/null || true)"
  up="$(printf '%s' "$t" | awk '{ n += gsub(/"health":"up"/, "") } END { print n + 0 }')"
  down="$(printf '%s' "$t" | awk '{ n += gsub(/"health":"down"/, "") } END { print n + 0 }')"
  [ "${down:-0}" = 0 ] && ok "prometheus targets: ${up:-0} up" || dwarn "prometheus targets: ${up:-0} up, $down down (http://127.0.0.1:$p/targets through the tunnel)"
  curl -fsS -m 5 "http://$MONITOR_BIND:$p/api/v1/rules" 2>/dev/null | grep VswBackupStale >/dev/null && ok "alert rules loaded" || bad "alert rules not loaded"
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$MONITOR_BIND:$g/api/dashboards/uid/vsw-overview")" = 401 ] && ok "grafana refuses anonymous access" || dwarn "grafana anonymous check inconclusive"
}
cmd_doctor() {
  local u any=0
  for u in $UNITS_ALL; do installed "$u" || continue; any=1; doctor_unit "$u"; done
  [ "$any" = 1 ] || { echo "no monitoring installed in $MONITOR_DIR"; return 0; }
  local a; a="$(mem MemAvailable)"; [ -z "$a" ] || { [ "$a" -ge 200 ] && ok "memory available: ${a} MB" || dwarn "memory available: ${a} MB"; }
  echo "doctor: $D_BAD problem(s), $D_WARN warning(s)"; [ "$D_BAD" -eq 0 ]
}
cmd_status() {
  local u any=0
  for u in $UNITS_ALL; do installed "$u" || continue; any=1; echo "== $u"; dcu "$u" ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'; done
  [ "$any" = 1 ] || echo "no monitoring installed in $MONITOR_DIR"
}
cmd_list() {
  local u
  printf '%-13s %-11s %-6s %6s  %-58s %s\n' UNIT STACK SIDE RAM_MB IMAGES INSTALLED
  for u in $UNITS_ALL; do ( load_unit "$u"
    printf '%-13s %-11s %-6s %6s  %-58s %s\n' "$u" "$MON_STACK" "$MON_SIDE" "$MON_RAM_MB" "$(images_of "$u" | tr '\n' ' ' | cut -c1-58)" "$(installed "$u" && echo yes || echo no)" ); done
  echo "MONITOR_STACKS picks stacks (default beszel,kuma); MONITOR_ROLE picks the side (hub, agent, both)."
}
cmd_remove() {
  local u="$1" ts d; need_root; need_docker; case " $UNITS_ALL " in *" $u "*) ;; *) CODE=2 die "unknown unit '$u' (one of: $UNITS_ALL)" ;; esac
  installed "$u" || die "$u is not installed here"; d="$(udir "$u")"
  echo "remove: $u; data $( [ "${OPT_DELETE_DATA:-0}" = 1 ] && echo "WILL BE DELETED: $d" || echo "kept in $MONITOR_DIR/.removed-$u-<ts>")"
  confirm "$u"
  if [ "${OPT_DELETE_DATA:-0}" = 1 ]; then
    [ -t 0 ] || [ "${OPT_FORCE:-0}" = 1 ] || die "--delete-data needs a terminal or --force"
    [ "${OPT_FORCE:-0}" = 1 ] || { local a; read -r -p "Type 'delete $u data' to erase $d: " a; [ "$a" = "delete $u data" ] || die "aborted"; }
  fi
  lock; dcu "$u" down --remove-orphans; ts="$(date +%Y%m%d%H%M%S)"
  if [ "${OPT_DELETE_DATA:-0}" = 1 ]; then rm -rf "${d:?}"; audit "$u" "removed with data"
  else mv "$d" "$MONITOR_DIR/.removed-$u-$ts"; audit "$u" "removed; files kept"; echo "files kept in $MONITOR_DIR/.removed-$u-$ts"; fi
  log "$u removed"
}

main() {
  local cmd="${1:-}" arg=""; [ $# -gt 0 ] && shift
  OPT_YES=0 OPT_FORCE=0 OPT_DELETE_DATA=0 OPT_OUT="" OPT_NAME="" OPT_HOST="" OPT_PORT="" OPT_DOMAIN=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) MONITOR_ROLE="${2:?--role needs a value}"; shift ;;
      --stacks) MONITOR_STACKS="${2:?--stacks needs a value}"; shift ;;
      --out) OPT_OUT="${2:?--out needs a value}"; shift ;;
      --name) OPT_NAME="${2:?--name needs a value}"; shift ;;
      --host) OPT_HOST="${2:?--host needs a value}"; shift ;;
      --port) OPT_PORT="${2:?--port needs a value}"; shift ;;
      --domain) OPT_DOMAIN="${2:?--domain needs a value}"; shift ;;
      --allow-tight) MONITOR_ALLOW_TIGHT=1 ;;
      --yes|-y) OPT_YES=1 ;;
      --force) OPT_FORCE=1 ;;
      --delete-data) OPT_DELETE_DATA=1 ;;
      -q|--quiet) export SIW_QUIET=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) CODE=2 die "unknown flag $1" ;;
      *) [ -z "$arg" ] || CODE=2 die "one argument at a time"; arg="$1" ;;
    esac; shift
  done
  case "$cmd" in
    list) cmd_list ;;
    plan) cmd_plan ;;
    install) cmd_install ;;
    targets) cmd_targets ;;
    beszel-register) cmd_beszel_register ;;
    beszel-key) cmd_beszel_key ;;
    tunnel) cmd_tunnel ;;
    caddy) cmd_caddy ;;
    status) need_docker; cmd_status ;;
    doctor) need_docker; validate; cmd_doctor ;;
    remove) [ -n "$arg" ] || CODE=2 die "usage: monitor.sh remove <unit>"; cmd_remove "$arg" ;;
    version|--version) echo "monitor.sh $VERSION" ;;
    ""|-h|--help|help) usage ;;
    *) CODE=2 die "unknown command '$cmd' (see --help)" ;;
  esac
}
[ "${MONITOR_SOURCE_ONLY:-0}" = 1 ] || main "$@"
