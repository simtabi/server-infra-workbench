#!/usr/bin/env python3
"""Build the provisioned Grafana dashboards (grafana/dashboards/*.json) from one small spec.

Why a generator: hand-edited dashboard JSON drifts (ids, datasource uids, grid positions). The spec below is
the source of truth; `--check` (run by `make test`) fails when the committed JSON differs from it.

    python3 stacks/monitor/prometheus/grafana/dashboards.py          # rewrite the JSON
    python3 stacks/monitor/prometheus/grafana/dashboards.py --check  # exit 1 on drift
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

DS = {"type": "prometheus", "uid": "vsw-prometheus"}
OUT = Path(__file__).resolve().parent / "dashboards"

# (title, expr, unit, kind) per panel; kind: ts = time series, stat = single value
SPEC: dict[str, tuple[str, list[tuple[str, str, str, str]]]] = {
    "vsw-overview": ("VSW overview: hosts", [
        ("Targets up", 'sum by (job) (up)', "short", "stat"),
        ("CPU busy", '1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m]))', "percentunit", "ts"),
        ("Memory available", 'node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "percentunit", "ts"),
        ("Load (15m) per CPU", 'node_load15 / on(instance) group_left count by (instance) (node_cpu_seconds_total{mode="idle"})', "short", "ts"),
        ("Disk used", '1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"}', "percentunit", "ts"),
        ("Network in", 'sum by (host) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*|br-.*"}[5m]))', "Bps", "ts"),
        ("Network out", 'sum by (host) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*|docker.*|br-.*"}[5m]))', "Bps", "ts"),
        ("Reboot required", 'max by (host) (vsw_reboot_required)', "short", "stat"),
    ]),
    "vsw-containers": ("VSW containers", [
        ("CPU per container", 'sum by (host, name) (rate(container_cpu_usage_seconds_total{name!=""}[5m]))', "short", "ts"),
        ("Memory per container", 'sum by (host, name) (container_memory_working_set_bytes{name!=""})', "bytes", "ts"),
        ("Network in per container", 'sum by (host, name) (rate(container_network_receive_bytes_total{name!=""}[5m]))', "Bps", "ts"),
        ("Containers running", 'count by (host) (container_last_seen{name!=""})', "short", "stat"),
    ]),
    "vsw-postgres": ("VSW Postgres + PgBouncer", [
        ("Postgres up", 'pg_up', "short", "stat"),
        ("PgBouncer up", 'pgbouncer_up', "short", "stat"),
        ("Connections / max", 'sum by (host) (pg_stat_activity_count) / max by (host) (pg_settings_max_connections)', "percentunit", "ts"),
        ("Database size", 'pg_database_size_bytes{datname!~"template.*"}', "bytes", "ts"),
        ("Transactions/s", 'sum by (host, datname) (rate(pg_stat_database_xact_commit{datname!~"template.*"}[5m]))', "ops", "ts"),
        ("PgBouncer clients waiting", 'sum by (host, database) (pgbouncer_pools_client_waiting_connections)', "short", "ts"),
        ("PgBouncer server connections", 'sum by (host, database) (pgbouncer_pools_server_active_connections)', "short", "ts"),
        ("Deadlocks/s", 'sum by (host) (rate(pg_stat_database_deadlocks[5m]))', "short", "ts"),
    ]),
    "vsw-backups": ("VSW backups + certificates", [
        ("Hours since last backup", '(time() - vsw_backup_last_success_timestamp_seconds) / 3600', "h", "stat"),
        ("Hours since off-site copy", '(time() - vsw_offsite_last_success_timestamp_seconds) / 3600', "h", "stat"),
        ("Days since restore test", '(time() - vsw_restore_test_last_success_timestamp_seconds) / 86400', "d", "stat"),
        ("DB TLS cert: days left", '(vsw_tls_cert_expiry_timestamp_seconds - time()) / 86400', "d", "stat"),
        ("Site certs: days left", '(probe_ssl_earliest_cert_expiry - time()) / 86400', "d", "stat"),
        ("Probe success", 'probe_success', "short", "ts"),
        ("Probe latency", 'probe_duration_seconds', "s", "ts"),
    ]),
}


def panel(i: int, title: str, expr: str, unit: str, kind: str) -> dict:
    w, h = (6, 4) if kind == "stat" else (12, 8)
    return {
        "id": i + 1, "type": "stat" if kind == "stat" else "timeseries", "title": title, "datasource": DS,
        "gridPos": {"x": 0, "y": 0, "w": w, "h": h},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {} if kind == "ts" else {"reduceOptions": {"calcs": ["lastNotNull"]}},
        "targets": [{"refId": "A", "datasource": DS, "expr": expr, "legendFormat": "__auto"}],
    }


def layout(panels: list[dict]) -> list[dict]:
    x = y = row_h = 0
    for p in panels:
        w, h = p["gridPos"]["w"], p["gridPos"]["h"]
        if x + w > 24:
            x, y, row_h = 0, y + row_h, 0
        p["gridPos"].update({"x": x, "y": y})
        x, row_h = x + w, max(row_h, h)
    return panels


def build(uid: str) -> str:
    title, rows = SPEC[uid]
    doc = {
        "uid": uid, "title": title, "tags": ["vsw"], "editable": False, "schemaVersion": 39, "version": 1,
        "time": {"from": "now-24h", "to": "now"}, "refresh": "1m", "timezone": "browser",
        "templating": {"list": []}, "annotations": {"list": []},
        "panels": layout([panel(i, *r) for i, r in enumerate(rows)]),
    }
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


def main(argv: list[str]) -> int:
    check = "--check" in argv
    drift = []
    OUT.mkdir(exist_ok=True)
    for uid in SPEC:
        f = OUT / f"{uid}.json"
        want = build(uid)
        if check:
            if not f.exists() or f.read_text() != want:
                drift.append(f.name)
        else:
            f.write_text(want)
    if drift:
        print("dashboards drifted (run stacks/monitor/prometheus/grafana/dashboards.py): " + ", ".join(drift), file=sys.stderr)
        return 1
    print(("dashboards ok: " if check else "wrote: ") + ", ".join(f"{u}.json" for u in SPEC))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
