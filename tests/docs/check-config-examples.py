#!/usr/bin/env python3
"""Config examples list the keys the code reads, and only those.

For each tool and its example config:
  missing: a `${KEY:-...}` / `${KEY:=...}` the script reads that the example never mentions
           (as `KEY=` or `# KEY=`), unless the key is internal (IGNORE) or a stack env key.
  dead:    a key in the example that neither the script nor the tool's stack templates use.

Usage: python3 tests/docs/check-config-examples.py [repo-root]   (exit 1 on a problem)
"""
import glob
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# (script, example, stack env templates whose keys the conf may override)
PAIRS = [
    ("src/shell/db/docker-db-server-manager.sh", "config/db-server.env.example", []),
    ("src/shell/monitor/monitor.sh", "config/monitor.conf.example", ["stacks/monitor/*/monitor.env.example"]),
    ("src/shell/addons/addon.sh", "config/addons.conf.example", ["stacks/addons/*/addon.env.example"]),
]

# Internal state, test hooks, the environment, and generated secrets: never config keys.
IGNORE = re.compile(
    r"^(OPT_\w+|CODE|FORCE|NONINTERACTIVE|SUDO_USER|TMPDIR|TERM|NO_COLOR|U_OWNER|REAL_DB_DIR|DOCTOR_CONTEXT|UPG_DRY|ALLOW_UNHEALTHY"
    r"|SIWO_\w+|PROGRESS_\w+|DBM_\w+|WORKBENCH_\w+|\w+_SOURCE_ONLY|\w+_ALLOW_NONROOT|\w+_CONF|\w+_FORCE_PROD"
    r"|GROUP_FILE|LOGROTATE_FILE|MONITOR_MEMINFO|MM_ALLOW_PLAIN|DIGITALOCEAN_TOKEN"
    r"|\w+_PASSWORD|\w+_SECRET_KEY|\w+_ACCESS_KEY)$"
)

READ = re.compile(r"\$\{([A-Z][A-Z0-9_]+):[-=]")
KEY = re.compile(r"^#?\s*([A-Z][A-Z0-9_]+)=", re.M)


def keys(path):
    with open(path, encoding="utf-8") as f:
        return set(KEY.findall(f.read()))


def main():
    problems = 0
    for script, example, stacks in PAIRS:
        with open(os.path.join(ROOT, script), encoding="utf-8") as f:
            code = f.read()
        listed = keys(os.path.join(ROOT, example))
        stack_keys = set()
        for pat in stacks:
            for p in glob.glob(os.path.join(ROOT, pat)):
                stack_keys |= keys(p)
        for k in sorted(set(READ.findall(code)) - listed - stack_keys):
            if not IGNORE.match(k):
                print(f"{example}: missing {k} (read by {script})")
                problems += 1
        for k in sorted(listed - stack_keys):
            if not re.search(r"\b" + k + r"\b", code):
                print(f"{example}: dead key {k} (not read by {script})")
                problems += 1
    print(f"check-config-examples: {len(PAIRS)} examples, {problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
