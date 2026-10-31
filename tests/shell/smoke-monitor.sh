#!/usr/bin/env bash
# Offline tests for src/shell/monitor/monitor.sh and src/shell/server/status.sh: validation, the RAM gate,
# plans per role, rendered Prometheus targets / Alertmanager / stack.env, the configurator's monitor conf, and
# status.sh against a fake sysroot. No Docker, no root, no network.
# shellcheck disable=SC2015,SC2016  # test one-liners; the bash -c bodies are literal
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
unset NO_COLOR VSW_QUIET MONITOR_CONF
M="$PWD/src/shell/monitor/monitor.sh"
mem() { printf 'MemTotal:       %d kB\nMemAvailable:   %d kB\n' $(( $1 * 1024 )) $(( $2 * 1024 )) > "$T/meminfo.$1"; echo "$T/meminfo.$1"; }
MONITOR_MEMINFO="$(mem 8192 6000)"
export MONITOR_DIR="$T/mon" MONITOR_CONF="$T/none.conf" MONITOR_AGENT_BIND=10.10.0.6 MONITOR_DB_NODE=0 \
       MONITOR_NODE_NAME=web1 MONITOR_PG_PASSWORD_FILE="$T/nope" AUDIT_LOG="$T/audit.log" MONITOR_MEMINFO
mon() { bash "$M" "$@"; }
code() { local rc=0; mon "$@" >"$T/o" 2>&1 || rc=$?; echo "$rc"; }

# ---- validation (exit 2 = configuration error) -------------------------------------------------
[ "$(code plan --stacks beszel,zabbix)" = 2 ] && grep -q "unknown stack 'zabbix'" "$T/o" && ok "unknown stack refused (exit 2)" || fail "unknown stack"
[ "$(MONITOR_BIND=0.0.0.0 code plan)" = 2 ] && grep -q 'loopback' "$T/o" && ok "UIs must bind loopback" || fail "MONITOR_BIND"
[ "$(MONITOR_AGENT_BIND=0.0.0.0 code plan)" = 2 ] && ok "agents never bind 0.0.0.0" || fail "agent 0.0.0.0"
[ "$(MONITOR_AGENT_BIND=8.8.8.8 code plan)" = 2 ] && grep -q 'not private' "$T/o" && ok "agents never bind a public IP (Docker bypasses ufw)" || fail "agent public"
[ "$(MONITOR_TARGETS='db=10.0.0.5 bad' code plan --stacks prometheus)" = 2 ] && ok "MONITOR_TARGETS entries must be name=host" || fail "targets"
[ "$(MONITOR_TARGETS='db=10.0.0.5' MONITOR_PG_TARGETS=web code plan --stacks prometheus)" = 2 ] && ok "MONITOR_PG_TARGETS must name a target" || fail "pg targets"
[ "$(MONITOR_PROBE_URLS='ftp://x' code plan)" = 2 ] && ok "probe URLs must be http(s)" || fail "probe"
[ "$(MONITOR_ALERT_EMAIL=ops@example.com code plan)" = 2 ] && grep -q SMARTHOST "$T/o" && ok "alert email needs an SMTP smarthost" || fail "email"
[ "$(MONITOR_ROLE=boss code plan)" = 2 ] && [ "$(code plan --foo)" = 2 ] && [ "$(code nonsense)" = 2 ] && ok "bad role, flag, command -> exit 2" || fail "args"
[ "$(code caddy --domain m.example.com)" = 2 ] && grep -q 'MONITOR_PUBLIC=1' "$T/o" && ok "caddy front needs MONITOR_PUBLIC=1 (tunnel by default)" || fail "caddy"

# ---- plans per role ------------------------------------------------------------------------------
mon plan --stacks beszel,kuma,prometheus > "$T/o" 2>&1
for u in beszel beszel-agent kuma prometheus exporters; do grep -qE "unit +$u " "$T/o" || fail "plan both: $u missing"; done
grep -q 'ui on 127.0.0.1 (tunnel)' "$T/o" && grep -q 'listens on 10.10.0.6 (host network)' "$T/o" && grep -q 'DB exporters off' "$T/o" \
  && ok "plan role=both: hub + agent units, loopback UIs, agent on the private IP" || { cat "$T/o"; fail "plan both"; }
mon plan --role hub --stacks beszel,prometheus > "$T/o" 2>&1
! grep -qE 'unit +(beszel-agent|exporters) ' "$T/o" && grep -qE 'unit +prometheus ' "$T/o" && ok "plan role=hub: no agents" || fail "plan hub"
mon plan --role agent --stacks beszel,kuma,prometheus > "$T/o" 2>&1
! grep -qE 'unit +(beszel|kuma|prometheus) ' "$T/o" && grep -q 'needs MONITOR_BESZEL_KEY_FILE' "$T/o" && grep -q 'firewall hub -> this node' "$T/o" \
  && ok "plan role=agent: agents only, asks for the hub key, prints the firewall rule" || { cat "$T/o"; fail "plan agent"; }
mon plan --stacks none > "$T/o" 2>&1 && grep -q 'nothing to install' "$T/o" && ok "MONITOR_STACKS=none installs nothing" || fail "none"
[ ! -e "$MONITOR_DIR" ] && ok "plan writes nothing" || fail "plan wrote $MONITOR_DIR"
printf 'MONITOR_STACKS=kuma\nMONITOR_ROLE=hub\n' > "$T/c.conf"; MONITOR_CONF="$T/c.conf" mon plan > "$T/o" 2>&1
grep -q 'role=hub stacks=kuma' "$T/o" && ok "settings come from MONITOR_CONF" || fail "conf"

# ---- RAM gate (exit 3) ---------------------------------------------------------------------------
[ "$(MONITOR_DB_NODE=1 MONITOR_MEMINFO="$(mem 2000 1500)" code plan --stacks beszel,prometheus)" = 3 ] && grep -q 'BLOCKED  prometheus' "$T/o" \
  && ok "RAM gate: prometheus next to a DB on 2 GB is refused (exit 3)" || { cat "$T/o"; fail "ram gate"; }
[ "$(MONITOR_DB_NODE=1 MONITOR_MEMINFO="$(mem 2000 1500)" code plan --stacks beszel,prometheus --allow-tight)" = 0 ] && grep -q 'allowed by MONITOR_ALLOW_TIGHT' "$T/o" \
  && ok "RAM gate: --allow-tight overrides with a warning" || fail "allow tight"
[ "$(MONITOR_DB_NODE=1 MONITOR_MEMINFO="$(mem 2000 1500)" code plan --stacks beszel,kuma)" = 0 ] && ok "RAM gate: light stacks pass on a 2 GB DB node" || fail "light"
[ "$(MONITOR_MEMINFO="$(mem 4096 300)" code plan --stacks prometheus,netdata)" = 3 ] && grep -q 'not enough memory' "$T/o" && ok "RAM gate: refuses when the estimate exceeds available memory" || fail "avail"

# ---- pinned images ---------------------------------------------------------------------------------
bad_img="$(grep -h '_IMAGE=' stacks/monitor/*/monitor.env.example | sed 's/[[:space:]]*#.*//' | grep -vE '=[^:]+:[^:]+$|=[^:]+:[^:]+@sha256' | grep -E ':latest$|=[^:]*$' || true)"
[ -z "$bad_img" ] && ok "every monitor image is pinned to a tag" || fail "unpinned: $bad_img"
! grep -RInE '(0\.0\.0\.0|"\*"):' stacks/monitor --include='*.yml' && ok "no compose file publishes on all interfaces" || fail "0.0.0.0 publish"
mon list > "$T/o" && [ "$(grep -cE '^(beszel|beszel-agent|kuma|netdata|prometheus|exporters) ' "$T/o")" = 6 ] && ok "list shows the 6 units" || fail "list"

# ---- rendered files (functions sourced, no Docker) ----------------------------------------------------
echo 'pw-should-not-leak' > "$T/pg.pass"; echo 'https://hooks.example.com/SECRET-HOOK' > "$T/hook"; echo 'smtp-pw-xyz' > "$T/smtp"
MONITOR_SOURCE_ONLY=1 MONITOR_TARGETS='db=10.10.0.5 web2=10.10.0.7' MONITOR_PG_TARGETS=db MONITOR_PROBE_URLS='https://app.example.com/up' \
MONITOR_PG=1 MONITOR_PG_PASSWORD_FILE="$T/pg.pass" MONITOR_ALERT_WEBHOOK_FILE="$T/hook" MONITOR_ALERT_EMAIL=ops@example.com \
MONITOR_SMTP_SMARTHOST=smtp.example.com:587 MONITOR_SMTP_USER=ops MONITOR_SMTP_PASSWORD_FILE="$T/smtp" bash -c '
  set -euo pipefail; source "$0"; MONITOR_STACKS=beszel,prometheus; validate; STACKS="$(stacks_dir)"
  mkdir -p "$MONITOR_DIR/prometheus" "$MONITOR_DIR/exporters"; render_targets; render_alertmanager
  ( load_unit exporters; stack_env exporters ) > "$MONITOR_DIR/exporters/stack.env"
  MONITOR_AGENT_NETWORK=bridge; ( load_unit exporters; stack_env exporters ) > "$MONITOR_DIR/exporters/stack.bridge.env"' "$M"
P="$MONITOR_DIR/prometheus"
python3 - "$P/targets" <<'PY' && ok "targets: valid file_sd JSON (local + remote nodes, PG exporters, probes)" || fail "targets json"
import json, sys, pathlib
d = pathlib.Path(sys.argv[1]); t = {f.stem: json.loads(f.read_text()) for f in d.glob("*.json")}
hosts = lambda k: sorted(x["labels"]["host"] for x in t[k])
assert hosts("node") == ["db", "web1", "web2"], t["node"]
assert [x["targets"][0] for x in t["postgres"]] == ["10.10.0.6:9187", "10.10.0.5:9187"], t["postgres"]
assert t["probes"][0]["targets"] == ["https://app.example.com/up"]
PY
grep -q 'url_file: /etc/alertmanager/secrets/webhook_url' "$P/alertmanager.yml" && grep -q 'auth_password_file:' "$P/alertmanager.yml" \
  && ! grep -qE 'SECRET-HOOK|smtp-pw-xyz' "$P/alertmanager.yml" && ok "alertmanager.yml points at secret files, never inlines them" || fail "alertmanager"
[ "$(stat -c %a "$P/am-secrets/webhook_url" 2>/dev/null || stat -f %Lp "$P/am-secrets/webhook_url")" = 400 ] && ok "alertmanager secret files are 400" || fail "am secret perms"
if python3 -c 'import yaml' 2>/dev/null; then python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$P/alertmanager.yml" && ok "alertmanager.yml is valid YAML" || fail "am yaml"; fi
E="$MONITOR_DIR/exporters"
grep -qx 'NODE_EXPORTER_LISTEN=10.10.0.6:9100' "$E/stack.env" && grep -qx 'COMPOSE_PROFILES=postgres' "$E/stack.env" && grep -qx 'NODE_EXPORTER_LISTEN=0.0.0.0:9100' "$E/stack.bridge.env" \
  && ! grep -q 'pw-should-not-leak' "$E/stack.env" && ok "stack.env: listen address per network mode, PG profile on, no password" || fail "stack.env"

# ---- the configurator's output is accepted by monitor.sh ------------------------------------------------
PYTHONPATH=src/python/src python3 - "$T" <<'PY'
import sys; from vps_server_workbench import profiles as P
r = P.resolve("production-single", {"CLIENT": "acme", "APP": "demo", "DB_PRIVATE_IP": "10.10.0.5", "WEB_PRIVATE_IP": "10.10.0.6",
                                     "MONITOR_STACKS": "beszel,kuma,prometheus", "MONITOR_PROBE_URLS": "https://app.example.com/up"})
for role in ("web", "db"): open(f"{sys.argv[1]}/monitor-{role}.conf", "w").write(P.render_monitor(r, role, "test"))
PY
MONITOR_CONF="$T/monitor-web.conf" mon plan > "$T/o" 2>&1 && grep -q 'role=both' "$T/o" && MONITOR_CONF="$T/monitor-db.conf" mon plan > "$T/o2" 2>&1 && grep -q 'role=agent' "$T/o2" \
  && ok "configure's monitor-web.conf / monitor-db.conf pass monitor.sh plan" || { cat "$T/o" "$T/o2"; fail "configure conf"; }

# ---- status.sh against a fake sysroot ------------------------------------------------------------------
R="$T/root"; mkdir -p "$R/proc" "$R/var/run" "$R/var/lib/vps-server-workbench/db" "$R/opt/vsw-monitor/beszel" "$T/bin"
printf '86400.5 1000\n' > "$R/proc/uptime"; printf '0.10 0.20 0.30 1/100 1\n' > "$R/proc/loadavg"
printf 'MemTotal: 4194304 kB\nMemAvailable: 2097152 kB\n' > "$R/proc/meminfo"; : > "$R/opt/vsw-monitor/beszel/stack.env"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
now="$(date +%s)"; echo "$now" > "$R/var/lib/vps-server-workbench/db/backup"; echo "$now ok 0" > "$R/var/lib/vps-server-workbench/db/doctor"
st() { env -u MONITOR_DIR PATH="$T/bin:$PATH" VSW_SYSROOT="$R" STATUS_DISK_WARN=100 bash src/shell/server/status.sh "$@"; }
st > "$T/o" && grep -q 'status: all fine' "$T/o" && grep -qE 'monitor +beszel' "$T/o" && grep -q 'uptime_days *1' "$T/o" && ok "status: healthy fake node -> exit 0" || { cat "$T/o"; fail "status ok"; }
st --json > "$T/o" && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ok"] is True and d["db_backup_age_h"]=="0"' "$T/o" && ok "status --json is valid JSON" || fail "status json"
echo $((now - 30 * 3600)) > "$R/var/lib/vps-server-workbench/db/backup"; : > "$R/var/run/reboot-required"
rc=0; st > "$T/o" || rc=$?; [ "$rc" = 1 ] && grep -q 'backup is 30 hours old' "$T/o" && grep -q 'reboot required' "$T/o" && ok "status: stale backup + reboot flag -> attention, exit 1" || { cat "$T/o"; fail "status attn"; }
rc=0; st --url 'ftp://x' >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] && ok "status: --url must be http(s)" || fail "status url"
bin/workbench monitor version | grep -q '^monitor.sh ' && bin/workbench status --help | grep -q 'one-screen health' && ok "workbench monitor / status dispatch" || fail "dispatch"
echo "smoke-monitor: all $pass checks passed"
