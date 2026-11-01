"""`siwo configure` (wizard or --non-interactive) and `siwo profile list|show|diff`.

configure picks a profile, applies overrides, validates RAM/region/VPC/best practice, and writes the
client's config into a git-ignored folder (default local/<client>/) with mode 600, a timestamped backup
of any file it changes, and a diff. It never writes secrets and never touches a server.
"""

from __future__ import annotations

import argparse
import difflib
import os
import subprocess  # noqa: S404 - only `git check-ignore` with fixed arguments
import sys
import time
from pathlib import Path

from server_infra_workbench import profiles as P

LEVEL_MARK = {"error": "ERROR", "warn": "warn ", "info": "info "}
WIZARD_KEYS = (  # asked in this order by the interactive wizard; everything else via KEY=VALUE overrides
    ("CLIENT", "client name (folder under local/)"),
    ("APP", "app name (databases are <app>_<env>)"),
    ("CLOUD", "cloud: do (DigitalOcean) | gcp (Google Cloud)"),
    ("REGION", "region: a DO slug (nyc3) or a GCP region (us-central1)"),
    ("ENVS", "environments on this DB droplet (space separated)"),
    ("DB_DROPLET_MB", "DB droplet RAM in MB"),
    ("WEB_DROPLET_MB", "web droplet RAM in MB"),
    ("DB_PRIVATE_IP", "DB droplet eth1 (VPC) address, empty to let the manager detect it"),
    ("STORAGE", "object storage: none | spaces | garage | seaweedfs | rustfs"),
    ("GOTENBERG", "Gotenberg PDF service: 1 = yes, 0 = no"),
    ("ALERT_EMAIL", "alert email (empty for none)"),
)


def _overrides(pairs: list[str]) -> dict[str, str]:
    out = {}
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep or not key.isupper():
            raise ValueError(f"--set needs KEY=VALUE (got {pair!r})")
        out[key] = value
    return out


def previous_overrides(path: Path) -> tuple[str, dict[str, str]]:
    """(profile, overrides) from an earlier workbench.conf: the lines tagged `# override`."""
    from server_infra_workbench import envfile

    text = path.read_text(encoding="utf-8")
    values = envfile.parse(text)
    keys = [ln.split("=", 1)[0].strip() for ln in text.splitlines() if ln.rstrip().endswith("# override")]
    out = {k: values[k] for k in keys if k in values}
    if values.get("CLIENT"):
        out["CLIENT"] = values["CLIENT"]
    return values.get("PROFILE", ""), out


def _print_findings(findings: list[tuple[str, str]], quiet_info: bool = False) -> int:
    errors = 0
    for level, msg in findings:
        if level == "info" and quiet_info:
            continue
        errors += level == "error"
        print(f"  {LEVEL_MARK[level]} {msg}")
    return errors


def _ask(prompt: str, default: str) -> str:
    try:
        answer = input(f"{prompt} [{default}]: ").strip()
    except EOFError:
        answer = ""
    return answer or default


def _git_ignored(path: Path, root: Path) -> bool | None:
    """True/False when `path` is inside the repo, None when it is outside."""
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return None
    try:
        rc = subprocess.run(  # noqa: S603
            ["git", "-C", str(root), "check-ignore", "-q", "--no-index", str(path.resolve())],  # noqa: S607
            capture_output=True,
            check=False,
        ).returncode
    except OSError:
        return path.resolve().is_relative_to((root / "local").resolve())
    return rc == 0


def _write_600(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o600)


def _plan_files(r: P.Resolved, out_dir: Path, stamp: str) -> dict[Path, str]:
    files = {out_dir / "workbench.conf": P.render_workbench(r, stamp)}
    if r.values["DB_MODE"] != "managed":
        target = out_dir / "db-server.conf"
        existing = target.read_text(encoding="utf-8") if target.is_file() else None
        files[target] = P.render_db(r, existing, stamp)
    for role in dict.fromkeys(role for _, role in P.addons_placed(r.values)):
        files[out_dir / f"addons-{role}.conf"] = P.render_addons(r, role, stamp)
    for role in P.monitor_placed(r.values):
        files[out_dir / f"monitor-{role}.conf"] = P.render_monitor(r, role, stamp)
    return files


def _same_ignoring_stamps(a: str, b: str) -> bool:
    def strip(t: str) -> list[str]:
        return [
            ln
            for ln in t.splitlines()
            if "written by `bin/siwo configure`" not in ln and "added by `bin/siwo configure`" not in ln
        ]

    return strip(a) == strip(b)


ENGINE_CMD = {
    "ENABLE_POSTGRES": "postgres",
    "ENABLE_PGBOUNCER": "pgbouncer",
    "ENABLE_MYSQL": "mysql",
    "ENABLE_MARIADB": "mariadb",
    "ENABLE_ADMINER": "adminer",
}


def engines_turned_off(previous: str | None, r: P.Resolved) -> list[str]:
    """Engines on in the earlier db-server.conf and off now (pgbouncer before postgres)."""
    if not previous:
        return []
    from server_infra_workbench import envfile

    old = envfile.parse(previous)
    off = [e for k, e in ENGINE_CMD.items() if old.get(k) == "1" and r.values.get(k) == "0"]
    return sorted(off, key=lambda e: e == "postgres")


def next_commands(r: P.Resolved, out_dir: Path, turned_off: list[str] | None = None) -> list[str]:
    v, rel = r.values, out_dir
    cmds = [f"# review the files in {rel}/ (no secrets in them)"]
    if turned_off:
        cmds.append("# engines turned off: disable them on the server FIRST (backs up, keeps the volume)")
        for e in turned_off:
            cmds += [
                f"ssh DB_HOST 'sudo /root/docker-db-server-manager.sh engine disable {e} --dry-run'",
                f"ssh -t DB_HOST 'sudo /root/docker-db-server-manager.sh engine disable {e}'",
            ]
    if v["DB_MODE"] != "managed":
        cmds += [
            "# DB droplet (DB_HOST = your SSH alias): back up the live config, then install the new one",
            f"scp {rel}/db-server.conf DB_HOST:/tmp/db-server.conf",
            "ssh DB_HOST 'sudo cp -p /etc/docker-db-server-manager.conf "
            "/etc/docker-db-server-manager.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null; "
            "sudo install -m 600 -o root -g root /tmp/db-server.conf /etc/docker-db-server-manager.conf "
            "&& rm /tmp/db-server.conf'",
        ]
    for role in dict.fromkeys(role for _, role in P.addons_placed(v)):
        host = {"db": "DB_HOST", "web": "WEB_HOST"}.get(role, "ADDON_HOST")
        names = [a for a, rl in P.addons_placed(v) if rl == role]
        cmds += [
            f"# add-ons on the {role} node: {' '.join(names)}",
            f"rsync -a src/shell/addons/addon.sh stacks/addons/ {host}:/tmp/siw-addons-src/",
            f"scp {rel}/addons-{role}.conf {host}:/tmp/addons.conf && ssh {host} 'sudo install -m 600 -o root "
            "-g root /tmp/addons.conf /etc/vsw-addons.conf && rm /tmp/addons.conf'",
        ]
        cmds += [f"ssh {host} 'sudo /tmp/siw-addons-src/addon.sh plan {n}'" for n in names]
    placed = P.monitor_placed(v)
    for role in sorted(placed, key=lambda rl: placed[rl] != "both"):  # hub first: agents need its key
        host = {"db": "DB_HOST", "web": "WEB_HOST"}.get(role, "MONITOR_HOST")
        cmds += [
            f"# monitoring on the {role} node ({placed[role]}): {','.join(P.monitor_stacks(v))}",
            f"rsync -a src/shell/monitor/monitor.sh src/shell/lib/progress.sh {host}:/tmp/siw-monitor-src/ "
            f"&& rsync -a stacks/monitor/ {host}:/tmp/siw-monitor-src/stacks/",
            f"scp {rel}/monitor-{role}.conf {host}:/tmp/monitor.conf && ssh {host} 'sudo install -m 600 -o root "
            "-g root /tmp/monitor.conf /etc/vsw-monitor.conf && rm /tmp/monitor.conf'",
        ]
        if role == "db" and v["DB_MODE"] != "managed" and "prometheus" in P.monitor_stacks(v):
            cmds.append(
                "ssh -t DB_HOST 'sudo /root/docker-db-server-manager.sh monitor-user'   # exporter login (password stays on the node)"
            )
        cmds.append(f"ssh -t {host} 'sudo /tmp/siw-monitor-src/monitor.sh plan'")
    if v["OFFSITE"] == "s3" and v["CLOUD"] == "gcp":
        cmds.append(
            "# GCS: create the bucket and an HMAC key of a service account limited to it (examples/gcp-vm)"
        )
    if v["STORAGE"] == "spaces" or (v["OFFSITE"] == "s3" and v["CLOUD"] != "gcp"):
        cmds.append(
            "# DO control panel: create the Spaces bucket(s) and a key limited to them (docs/tools/addons.md)"
        )
    if v["DO_ALERTS"] == "1" or v["UPTIME_CHECKS"] == "1":
        cmds.append("bin/siwo do uptime --help   # alert policies and uptime checks (plan first, then --yes)")
    if v["DB_MODE"] != "managed":
        cmds.append(
            "ssh -t DB_HOST 'sudo /root/docker-db-server-manager.sh upgrade --dry-run'   # last: shows every change"
        )
    return cmds


def run_configure(args: argparse.Namespace) -> int:
    root = P.repo_root()
    names = P.available(root)
    overrides = _overrides(args.set or [])
    if args.client:
        overrides["CLIENT"] = args.client
    profile = args.profile
    if args.keep:
        client = overrides.get("CLIENT", "")
        prev = Path(args.out_dir or root / "local" / client) / "workbench.conf"
        if not client or not prev.is_file():
            print(f"configure: --keep needs --client and an earlier {prev}", file=sys.stderr)
            return 2
        prev_profile, prev_over = previous_overrides(prev)
        overrides = {**prev_over, **overrides}
        profile = profile or prev_profile
        print(
            f"keeping earlier overrides from {prev}: "
            + (" ".join(f"{k}={v}" for k, v in prev_over.items() if k != "CLIENT") or "none")
        )
    interactive = not args.non_interactive
    if interactive:
        print("profiles:")
        for i, name in enumerate(names, 1):
            print(f"  {i}. {name:24} {P.load(name, root).get('PROFILE_DESCRIPTION', '')}")
        pick = _ask("profile (number or name)", profile or "dev-budget")
        profile = names[int(pick) - 1] if pick.isdigit() and 0 < int(pick) <= len(names) else pick
    if not profile:
        print("configure: --profile is required with --non-interactive", file=sys.stderr)
        return 2
    try:
        r = P.resolve(profile, overrides, root)
        if interactive:
            for key, prompt in WIZARD_KEYS:
                overrides[key] = _ask(prompt, r.values.get(key, ""))
            while True:
                extra = _ask("other override KEY=VALUE (empty to finish)", "")
                if not extra:
                    break
                overrides.update(_overrides([extra]))
            r = P.resolve(
                profile, {k: v for k, v in overrides.items() if v != r.values.get(k) or k == "CLIENT"}, root
            )
    except ValueError as exc:
        print(f"configure: {exc}", file=sys.stderr)
        return 2
    client = r.values.get("CLIENT", "")
    if not client:
        print("configure: --client is required (names the local/<client>/ folder)", file=sys.stderr)
        return 2

    print(f"\nprofile {r.profile} v{r.version} for {client}")
    changed = [k for k, s in r.source.items() if s == "override" and k != "CLIENT"]
    if changed:
        print("overrides: " + " ".join(f"{k}={r.values[k]}" for k in changed))
    print("checks:")
    errors = _print_findings(P.validate(r))
    if errors:
        print(f"\nconfigure: {errors} error(s); nothing written", file=sys.stderr)
        return 1

    out_dir = Path(args.out_dir) if args.out_dir else root / "local" / client
    if _git_ignored(out_dir, root) is False:
        print(
            f"configure: {out_dir} is inside the repo but not git-ignored; refusing (use local/<client>/)",
            file=sys.stderr,
        )
        return 1
    stamp = time.strftime("%Y-%m-%d %H:%M %Z")
    db_conf = out_dir / "db-server.conf"
    turned_off = engines_turned_off(db_conf.read_text(encoding="utf-8") if db_conf.is_file() else None, r)
    for e in turned_off:
        print(
            f"  warn  {e} was enabled in {db_conf}; disable it on the server before installing the new file"
        )
    files = _plan_files(r, out_dir, stamp)
    pending: dict[Path, str] = {}
    for path, text in files.items():
        old = path.read_text(encoding="utf-8") if path.is_file() else ""
        if old and _same_ignoring_stamps(old, text):
            print(f"\n{path}: unchanged")
            continue
        pending[path] = text
        print(f"\n{path}: {'update' if old else 'new'}")
        sys.stdout.writelines(
            difflib.unified_diff(old.splitlines(True), text.splitlines(True), "current", "new", n=1)
        )
    if not pending:
        print("\nnothing to write")
    elif args.dry_run:
        print("\n--dry-run: nothing written")
    else:
        updates = [p for p in pending if p.exists()]
        if updates and not args.yes:
            if not interactive:
                print("configure: existing files would change; re-run with --yes", file=sys.stderr)
                return 1
            if _ask("write these files (backups are kept)? yes/no", "no") != "yes":
                print("nothing written")
                return 1
        ts = time.strftime("%Y%m%d-%H%M%S")
        for path, text in pending.items():
            if path.exists():
                backup = path.with_name(f"{path.name}.bak.{ts}")
                _write_600(backup, path.read_text(encoding="utf-8"))
                print(f"backup  {backup}")
            _write_600(path, text)
            print(f"wrote   {path} (600)")
    print("\nnext:")
    for line in next_commands(r, out_dir, turned_off):
        print(f"  {line}")
    return 0


def run_profile(args: argparse.Namespace) -> int:
    root = P.repo_root()
    try:
        if args.action == "list":
            for name in P.available(root):
                prof = P.load(name, root)
                print(
                    f"{name:24} v{prof.get('PROFILE_VERSION', '?'):3} {prof.get('PROFILE_DESCRIPTION', '')}"
                )
            return 0
        if args.action == "table":
            sys.stdout.write(P.markdown_table(root))
            return 0
        if args.action == "show":
            if not args.names:
                raise ValueError("profile show NAME")
            r = P.resolve(args.names[0], _overrides(args.set or []), root)
            print(f"# {r.profile} v{r.version}: {r.values.get('PROFILE_DESCRIPTION', '')}")
            print("# * = set by the profile, + = override, ~ = derived; others from _defaults.conf")
            mark = {"profile": "*", "override": "+", "derived": "~"}
            for k, val in r.values.items():
                if k not in P.META:
                    print(f"{mark.get(r.source[k], ' ')} {k}={val}")
            if args.check:
                return 1 if _print_findings(P.validate(r)) else 0
            return 0
        if args.action == "diff":
            if not 1 <= len(args.names) <= 2:
                raise ValueError("profile diff A [B]  (one name: against _defaults.conf)")
            a = P.resolve(args.names[0], root=root).values if len(args.names) == 2 else P.defaults(root)
            b = P.resolve(args.names[-1], root=root).values
            left = args.names[0] if len(args.names) == 2 else "_defaults"
            rows = P.diff(a, b)
            if not rows:
                print("no differences")
            width = max((len(k) for k, _, _ in rows), default=0)
            print(f"{'KEY':{width}}  {left} -> {args.names[-1]}")
            for k, x, y in rows:
                print(f"{k:{width}}  {x or '(empty)'} -> {y or '(empty)'}")
            return 0
    except ValueError as exc:
        print(f"profile: {exc}", file=sys.stderr)
        return 2
    return 2


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="siwo", description="profiles and the configurator")
    sub = p.add_subparsers(dest="command", required=True)
    c = sub.add_parser("configure", help="pick a profile, override, validate, write local/<client>/")
    c.add_argument("--profile", help="profile name (see: siwo profile list)")
    c.add_argument("--client", help="client name; files go to local/<client>/")
    c.add_argument("--set", action="append", metavar="KEY=VALUE", help="override a setting (repeatable)")
    c.add_argument(
        "--keep",
        action="store_true",
        help="start from the overrides (and profile) in the earlier local/<client>/workbench.conf",
    )
    c.add_argument("--non-interactive", action="store_true", help="no prompts; needs --profile and --client")
    c.add_argument(
        "--out-dir", help="write here instead of local/<client>/ (must be git-ignored or outside the repo)"
    )
    c.add_argument("--dry-run", action="store_true", help="validate and show diffs, write nothing")
    c.add_argument(
        "--yes", action="store_true", help="overwrite existing files without asking (backups are kept)"
    )
    pr = sub.add_parser("profile", help="list | show NAME [--check] | diff A [B] | table")
    pr.add_argument("action", choices=("list", "show", "diff", "table"))
    pr.add_argument("names", nargs="*")
    pr.add_argument("--set", action="append", metavar="KEY=VALUE", help="show with overrides")
    pr.add_argument("--check", action="store_true", help="show: also run the validation checks")
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    try:
        return run_configure(args) if args.command == "configure" else run_profile(args)
    except KeyboardInterrupt:
        print("\naborted; nothing written", file=sys.stderr)
        return 130
