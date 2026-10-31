#!/usr/bin/env python3
"""Generate docs/reference/configuration-keys.md from config/db-server.env.example.

Usage: python3 tests/docs/gen-config-keys.py [--check]
--check exits 1 when the page is out of date (used by `make docs`).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "config/db-server.env.example"
DST = ROOT / "docs/reference/configuration-keys.md"

HEAD = """# Configuration keys (DB server manager)

Every key `docker-db-server-manager.sh` reads from `/etc/docker-db-server-manager.conf` (or `--config FILE`,
`DBM_CONFIG=FILE`). Environment variables override the file. The file holds no secrets: passwords are
generated into `$DB_DIR/.env` and `$ENV_SECRETS_DIR/<env>.env` (both chmod 600). This page is generated from
[config/db-server.env.example](../../config/db-server.env.example); edit the example, then run
`python3 tests/docs/gen-config-keys.py`.
"""

TAIL = """## Per-environment keys (not in the example)

| Key | Default | Notes |
|---|---|---|
| `ALLOW_<env>` | `ALLOW_default` | comma-separated IPv4/CIDR allowed to log in as that env's roles (`pg_hba`); written by `env-init --allow env=CIDR` |
| `ALLOW_default` | `VPC_CIDR` | fallback for envs without their own `ALLOW_<env>` |
| `WORKBENCH_CONFIRM` | (environment only) | the protected env's name (e.g. `prd`) for destructive commands with `--force-prod` and no terminal |
| `DBM_CONFIG` | `/etc/docker-db-server-manager.conf` | (environment only) the config file path |
"""


def render() -> str:
    out = [HEAD]
    sec, pend, rows, seen, defaults = None, [], [], set(), False

    def flush():
        if sec and rows:
            out.extend([f"## {sec}", "", "| Key | Default | Notes |", "|---|---|---|", *rows, ""])
        rows.clear()

    for line in SRC.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^# -{3,4} (.+?) -*$", line)
        if m:
            flush()
            sec = re.sub(r"\s*\([^)]*see [^)]*\)", "", m.group(1)).strip()
            pend = []
            continue
        if line.startswith("# ===="):
            defaults, pend = True, []  # below this marker, commented keys show the defaults
            continue
        m = re.match(r"^(#?)([A-Z][A-Z0-9_]+)=(.*)$", line)
        if m and sec:
            commented, key, val = m.groups()
            note = ""
            if "   # " in val:
                val, note = val.split("   # ", 1)
            val = val.strip().strip('"')
            if not note and pend:
                note = " ".join(pend)
            pend = []
            if key in seen:
                continue
            seen.add(key)
            if commented and not defaults:
                default = f"(unset; example `{val}`)" if val else "(unset)"
            else:
                default = f"`{val}`" if val else "(empty)"
            rows.append(f"| `{key}` | {default} | {note.replace('|', chr(92) + '|')} |")
            continue
        if line.startswith("# ") and sec:
            pend.append(line[2:].strip())
        elif not line.strip():
            pend = []
    flush()
    out.append(TAIL)
    return "\n".join(out)


if __name__ == "__main__":
    text = render()
    if "--check" in sys.argv:
        if DST.read_text(encoding="utf-8") != text:
            print(f"{DST.relative_to(ROOT)} is out of date: run python3 tests/docs/gen-config-keys.py")
            sys.exit(1)
        print("configuration-keys.md is up to date")
    else:
        DST.write_text(text, encoding="utf-8")
        print(f"wrote {DST.relative_to(ROOT)}")
