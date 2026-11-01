#!/usr/bin/env python3
"""no-env-files: fail when a real env file or a generated credentials file is tracked or staged.

The workstation .env holds the real master passwords (see .env-example); it is git-ignored and must never
reach a commit. Templates stay tracked: .env-example, .env.example, *.env.example, *.example.
Checks: (1) every tracked or staged path, (2) that .env itself is still git-ignored.
File names only: contents are never read or printed.

  python3 tests/security/no-env-files.py [--staged] [--self-test]
"""
import re
import subprocess
import sys

TEMPLATE = re.compile(r"(?:^|/)(?:\.env-example|\.env\.example|[^/]*\.env\.example|[^/]*\.example)$")
BAD = [
    (re.compile(r"(?:^|/)\.env$"), "a .env file"),
    (re.compile(r"(?:^|/)\.env\.[^/]+$"), "a .env.* file"),
    (re.compile(r"(?:^|/)[^/]+\.env(?:\.local)?$"), "an *.env file"),
    (re.compile(r"(?:^|/)[^/]+\.creds(?:\.[^/]+)?$"), "a credentials file (--out FILE)"),
    (re.compile(r"(?:^|/)id_(?:rsa|ed25519|ecdsa|dsa)(?:\.pub)?$|\.(?:pem|key|p12|pfx)$"), "a key file"),
]


def verdict(path):
    if TEMPLATE.search(path):
        return None
    for rx, what in BAD:
        if rx.search(path):
            return what
    return None


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False).stdout.split("\0")


def self_test():
    bad = [".env", "sub/.env", ".env.prod", "prod.env", "x.env.local", "shop.creds", "shop.creds.readonly", "id_ed25519", "a/server.key"]
    good = [".env-example", ".env.example", "config/db-server.env.example", "stacks/caddy/.env.example", "src/shell/env/env.sh",
            "docs/tools/env.md", "src/python/src/server_infra_workbench/envfile.py", "config/credentials.env.example"]
    fails = [p for p in bad if not verdict(p)] + [p for p in good if verdict(p)]
    for p in fails:
        print(f"self-test FAIL: {p}")
    print(f"no-env-files self-test: {len(bad) + len(good) - len(fails)}/{len(bad) + len(good)} ok")
    return 1 if fails else 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    staged = [p for p in git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR") if p]
    paths = staged if "--staged" in argv else sorted(set(p for p in git("ls-files", "-z") if p) | set(staged))
    problems = [(p, w) for p in paths if (w := verdict(p))]
    for p, w in problems:
        print(f"!! {p}: {w} must never be committed (untrack it, keeping the file: git rm --cached -- '{p}')")
    if subprocess.run(["git", "check-ignore", "-q", "--no-index", ".env"], check=False).returncode != 0:
        problems.append((".env", "not ignored"))
        print("!! .env is not git-ignored any more: restore the .env rule in .gitignore")
    print(f"no-env-files: {len(paths)} path(s) checked, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
