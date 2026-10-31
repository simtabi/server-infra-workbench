#!/usr/bin/env bash
# Docker integration test for src/shell/monitor/monitor.sh next to the DB manager (one node, role=both,
# bridge network so it runs under Docker Desktop/OrbStack too). Installs Postgres + PgBouncer, the
# vsw_monitor role, then Beszel (hub + agent), Uptime Kuma and Prometheus + Grafana + Alertmanager +
# exporters, and checks: health, loopback-only binds, secret file modes, Prometheus targets incl. the
# DB exporters, the manager's textfile metrics, alert rules, Grafana provisioning and auth, Beszel
# registration, probes, idempotent re-install, remove keeps data. Netdata is covered by smoke-monitor
# (plan/RAM gate) only: it needs host /proc and /sys that a desktop VM does not mirror faithfully.
# Leaves nothing behind (trap). Last outputs are copied to /tmp/vsw-mon-last on exit.
# shellcheck disable=SC2015  # test one-liners
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "monitor-it skipped (no docker)"; exit 0; }
unset NO_COLOR
M="$PWD/src/shell/db/docker-db-server-manager.sh" MON="$PWD/src/shell/monitor/monitor.sh"
W="$(mktemp -d /tmp/vsw-mon.XXXX)"; D="$W/vswmon"
pass=0; ok() { pass=$((pass + 1)); echo "ok   $1"; }; fail() { echo "FAIL $1" >&2; exit 1; }
cleanup() { rm -rf /tmp/vsw-mon-last; mkdir -p /tmp/vsw-mon-last; cp "$W"/*.out "$W/audit.log" /tmp/vsw-mon-last/ 2>/dev/null || true
  local u; for u in prometheus exporters kuma beszel-agent beszel; do for d in "$W/mon/$u" "$W"/mon/.removed-"$u"-*; do
    [ -f "$d/stack.env" ] && (cd "$d" && docker compose --env-file stack.env --env-file secrets.env down -v --remove-orphans >/dev/null 2>&1) || true; done; done
  [ -d "$D" ] && (cd "$D" && docker compose --env-file .env --env-file stack.env down -v --remove-orphans >/dev/null 2>&1) || true
  docker network rm vsw_monitor >/dev/null 2>&1 || true
  docker run --rm -v "$W:/w" alpine:3.22 rm -rf /w/mon >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
docker network inspect vsw_monitor >/dev/null 2>&1 && { echo "monitor-it: a vsw_monitor network already exists here; refusing to touch it"; trap - EXIT; rm -rf "$W"; exit 1; }
mkdir -p "$W/textfile"
printf 'PG_BASE_IMAGE=postgres:18\nPG_IMAGE=vsw-test/postgres:18\nPGVECTOR_PKG=postgresql-18-pgvector\n' > "$W/dbm.conf"; chmod 600 "$W/dbm.conf"
export DB_DIR="$D" PRIVATE_IP=127.0.0.1 VPC_CIDR=127.0.0.0/8 DBM_CONFIG="$W/dbm.conf" DBM_LOCK="$W/lock" DBM_LOG="$W/run.log" \
  BACKUP_DIR="$W/backups" MIN_FREE_MB=10 STATE_DIR="$W/state" ENV_SECRETS_DIR="$W/secrets" DOCKER_SUBNET=172.30.97.0/24 DOCKER_NETWORK=vsw_dbm \
  ENABLE_MYSQL=0 ENABLE_MARIADB=0 ENABLE_ADMINER=0 PG_PORT=25451 PGBOUNCER_PORT=26451 PG_USER=app PG_DB=app \
  METRICS_TEXTFILE_DIR="$W/textfile" MONITOR_PASSWORD_FILE="$W/pg-monitor.pass"
run() { bash -c 'm="$1"; shift; a=("$@"); set --; DBM_SOURCE_ONLY=1 source "$m"; need_root(){ :; }; check_engines; take_lock; "${a[@]}"' _ "$M" "$@"; }
# monitor.sh config: ports moved off the defaults so a developer's own services don't collide
cat > "$W/monitor.conf" <<CONF
MONITOR_STACKS=beszel,kuma,prometheus
MONITOR_ROLE=both
MONITOR_NODE_NAME=itnode
MONITOR_DIR=$W/mon
MONITOR_AGENT_BIND=127.0.0.1
MONITOR_AGENT_NETWORK=bridge
MONITOR_PG=1
MONITOR_PG_PASSWORD_FILE=$W/pg-monitor.pass
MONITOR_DB_NETWORK=vsw_dbm
MONITOR_TEXTFILE_DIR=$W/textfile
MONITOR_DB_NODE=0
BESZEL_PORT=28090
KUMA_PORT=23001
GRAFANA_PORT=23300
PROMETHEUS_PORT=29090
ALERTMANAGER_PORT=29093
NODE_EXPORTER_PORT=29100
CADVISOR_PORT=29338
POSTGRES_EXPORTER_PORT=29187
PGBOUNCER_EXPORTER_PORT=29127
BESZEL_AGENT_PORT=25876
CONF
chmod 600 "$W/monitor.conf"
mon() { MONITOR_CONF="$W/monitor.conf" MONITOR_ALLOW_NONROOT=1 AUDIT_LOG="$W/audit.log" WAIT_TIMEOUT=300 bash "$MON" "$@"; }
prom() { curl -fsS -m 10 "http://127.0.0.1:29090$1"; }
q() { prom "/api/v1/query?query=$1" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")'; }

# ---- the DB side: manager install, vsw_monitor role, a backup for the textfile metrics -----------------------------
run cmd_install > "$W/install.out" 2>&1 && grep -q 'ALL CHECKS PASSED' "$W/install.out" && ok "manager install (postgres + pgbouncer)" || { tail -40 "$W/install.out"; fail "install"; }
run cmd_monitor_user > "$W/mu.out" 2>&1 && [ "$(stat -f %Lp "$W/pg-monitor.pass" 2>/dev/null || stat -c %a "$W/pg-monitor.pass")" = 600 ] \
  && ! cat "$W/mu.out" "$DBM_LOG" 2>/dev/null | grep -qF "$(cat "$W/pg-monitor.pass")" && ok "monitor-user: role created, password file 600, never printed" || { cat "$W/mu.out"; fail "monitor-user"; }
run cmd_monitor_user > "$W/mu2.out" 2>&1 && ok "monitor-user is idempotent" || { cat "$W/mu2.out"; fail "monitor-user rerun"; }
(cd "$D" && docker compose --env-file .env --env-file stack.env exec -T postgres psql -X -tA -U vsw_admin -d postgres \
  -c "select rolsuper::int::text || pg_has_role('vsw_monitor','pg_monitor','member')::int::text || rolconnlimit::text from pg_roles where rolname='vsw_monitor'") | grep -qx '015' \
  && ok "vsw_monitor: not superuser, member of pg_monitor, connection limit 5" || fail "role attrs"
run cmd_backup > "$W/bk.out" 2>&1 && grep -q 'vsw_backup_last_success_timestamp_seconds' "$W/textfile/vsw_db.prom" && ok "backup writes the textfile metrics" || { tail -20 "$W/bk.out"; fail "backup"; }

# ---- monitoring install ----------------------------------------------------------------------------------------
mon plan > "$W/plan.out" 2>&1 && grep -q 'postgres-exporter, pgbouncer-exporter' "$W/plan.out" && ok "plan: 5 units, DB exporters on" || { cat "$W/plan.out"; fail "plan"; }
mon install --yes > "$W/mi.out" 2>&1 && grep -q 'monitoring is up on itnode' "$W/mi.out" && ok "install: beszel, beszel-agent, kuma, prometheus, exporters healthy" || { tail -60 "$W/mi.out"; fail "monitor install"; }
bad=0; for u in beszel beszel-agent kuma prometheus exporters; do for f in secrets.env stack.env; do
  [ "$(stat -f %Lp "$W/mon/$u/$f" 2>/dev/null || stat -c %a "$W/mon/$u/$f")" = 600 ] || bad=1; done; done
[ "$bad" = 0 ] && ok "every secrets.env / stack.env is 600" || fail "modes"
leak=0; for u in beszel prometheus exporters; do while IFS='=' read -r _ v; do [ -n "$v" ] && [ "${#v}" -ge 12 ] && grep -qF "$v" "$W/mi.out" "$W/audit.log" && leak=1; done < <(grep -v '^#' "$W/mon/$u/secrets.env"); done
[ "$leak" = 0 ] && ok "no generated secret appears in the output or the audit log" || fail "secret leaked"
ips="$(docker ps --filter name=vsw-mon- --format '{{.Ports}}' | tr ',' '\n' | grep -oE '^ *[][0-9a-f.:]+:[0-9]+->' | sed -E 's/^ *//; s/:[0-9]+->$//' | sort -u | tr '\n' ' ')" || true
[ "$ips" = "127.0.0.1 " ] && ok "every published monitor port is on 127.0.0.1" || fail "binds: '$ips'"

# ---- Prometheus: targets, DB exporters, textfile metrics, rules --------------------------------------------------
for _ in $(seq 1 45); do
  t="$(prom /api/v1/targets?state=active 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["data"]["activeTargets"]; print(" ".join(sorted(x["labels"]["job"]+"="+x["health"] for x in a)))' 2>/dev/null || true)"
  case "$t" in *down*|*unknown*|"") sleep 4 ;; *) break ;; esac
done
for j in node cadvisor postgres pgbouncer; do [[ " $t " == *" $j=up "* ]] || { echo "targets: $t"; fail "target $j not up"; }; done
ok "prometheus targets up: node, cadvisor, postgres, pgbouncer ($t)"
[ "$(q pg_up)" = 1 ] && ok "postgres-exporter logs in as vsw_monitor (pg_up 1)" || fail "pg_up"
[ "$(q pgbouncer_up)" = 1 ] && ok "pgbouncer-exporter reads SHOW STATS (pgbouncer_up 1)" || fail "pgbouncer_up"
[ -n "$(q vsw_backup_last_success_timestamp_seconds)" ] && ok "node-exporter serves the manager's textfile metrics" || fail "textfile metric"
prom /api/v1/rules | grep -q VswBackupStale && [ "$(prom /api/v1/rules | grep -o '"type":"alerting"' | wc -l | tr -d ' ')" -ge 10 ] && ok "alert rules loaded (VswBackupStale and the rest)" || fail "rules"
curl -fsS -m 10 http://127.0.0.1:29093/-/ready >/dev/null && ok "alertmanager ready" || fail "alertmanager"

# ---- Grafana: auth + provisioning ---------------------------------------------------------------------------------
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:23300/api/search)" = 401 ] && ok "grafana refuses anonymous access" || fail "grafana anon"
gpw="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' "$W/mon/prometheus/secrets.env")"
g() { printf 'user = "admin:%s"\n' "$gpw" | curl -fsS -m 10 -K - "http://127.0.0.1:23300$1"; }
g /api/datasources | grep -q '"type":"prometheus"' && [ "$(g '/api/search?query=vsw' | grep -o '"uid":"vsw-' | wc -l | tr -d ' ')" -ge 4 ] \
  && ok "grafana: prometheus datasource + the 4 vsw dashboards provisioned" || fail "grafana provisioning"

# ---- Beszel + Kuma -----------------------------------------------------------------------------------------------
mon beszel-register --name itnode --host beszel-agent --port 45876 > "$W/bz.out" 2>&1 && grep -q 'already registered' "$W/bz.out" \
  && ok "beszel: this node's agent was registered by install (re-register is a no-op)" || { cat "$W/bz.out"; fail "beszel register"; }
mon beszel-key --out "$W/hub.pub" > "$W/bk2.out" 2>&1 && grep -qE '^ssh-ed25519 ' "$W/hub.pub" && ok "beszel-key: hub public key exported" || { cat "$W/bk2.out"; fail "beszel-key"; }
curl -fsS -m 10 -o /dev/null http://127.0.0.1:23001/ && ok "uptime kuma answers on loopback" || fail "kuma"

# ---- doctor, tunnel, probes via targets, idempotent re-install, remove ---------------------------------------------------
mon doctor > "$W/doc.out" 2>&1 && grep -q 'doctor: 0 problem' "$W/doc.out" && ok "monitor doctor: 0 problems" || { cat "$W/doc.out"; fail "doctor"; }
mon tunnel --host me@db > "$W/tun.out" 2>&1 && grep -q -- '-L 23300:127.0.0.1:23300' "$W/tun.out" && grep -q 'me@db' "$W/tun.out" && ok "tunnel prints the ssh -L line for every UI" || { cat "$W/tun.out"; fail "tunnel"; }
echo 'MONITOR_PROBE_URLS=http://kuma:3001/' >> "$W/monitor.conf"
mon targets > "$W/tg.out" 2>&1 || { cat "$W/tg.out"; fail "targets"; }
for _ in $(seq 1 30); do [ "$(q 'probe_success')" = 1 ] && break; sleep 3; done
[ "$(q 'probe_success')" = 1 ] && ok "targets: a new probe URL is picked up without a restart (blackbox probe_success 1)" || fail "probe"
h1="$(cat "$W"/mon/*/secrets.env | shasum | cut -c1-12)"
mon install --yes > "$W/mi2.out" 2>&1 && [ "$(cat "$W"/mon/*/secrets.env | shasum | cut -c1-12)" = "$h1" ] && ok "re-install is idempotent and keeps every secret" || { tail -30 "$W/mi2.out"; fail "reinstall"; }
mon remove kuma --yes > "$W/rm.out" 2>&1 && ls -d "$W"/mon/.removed-kuma-* >/dev/null 2>&1 && [ -z "$(docker ps -q --filter name=vsw-mon-kuma)" ] \
  && ok "remove kuma: containers gone, files kept" || { cat "$W/rm.out"; fail "remove"; }
grep -q 'unit=kuma removed; files kept' "$W/audit.log" && ok "audit log records installs and the removal" || fail "audit"
echo "monitor-it: all $pass checks passed"
