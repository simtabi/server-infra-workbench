#!/usr/bin/env python3
"""Check that every documented `bin/workbench ...` and `src/shell/<area>/<tool>.sh ...` command exists.

Why: docs drift silently. A renamed subcommand or flag keeps working in the README long after the
tool stopped accepting it, and the first person to notice is someone copying it onto a server.
This reads every Markdown file (code spans and fenced blocks), resolves the tool the same way
bin/workbench does, and checks the subcommand and every --flag against that tool's own --help.
Offline: only --help/help is run, never a real command.

Also checked (added in the docs audit, each one a bug that reached a doc):
- DB manager commands: `M <cmd>` (the checklists' shorthand), `.../docker-db-server-manager.sh <cmd>` and each
  comma-separated command after `remote-run.sh ... --`, against the manager's own dispatch table and --help.
- PHP commands: a value option given twice (the parser keeps one; now a usage error), and a "(destructive)"
  command without --force (it can't run that way).
- Coverage the other way: every manager command, shell tool and PHP subcommand is named in some doc.

Exit 1 on any unknown tool, subcommand or flag.   Usage: python3 tests/docs/check-commands.py [root]
Inline opt-out for a deliberate example of a wrong command: `<!-- vsw-commands: ignore -->` on the line.
"""
import os, re, subprocess, sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
WB = os.path.join(root, "bin", "workbench")
CMD = re.compile(r"(?:\./)?(bin/workbench|src/shell/[a-z0-9-]+/[a-z0-9-]+\.sh)((?:[ \t]+(?:<[^\s<>`]+>|[^\s`|;&#)<>])+)*)")
MGR_PATH = "src/shell/db/docker-db-server-manager.sh"
MGR = re.compile(r"(?:^|[\s(`])(?:sudo\s+)?(?:[\w./~-]*/)?docker-db-server-manager\.sh((?:[ \t]+(?:<[^\s<>`]+>|[^\s`|;&#)<>])+)*)")
M_SPAN = re.compile(r"^\s*(?:sudo\s+)?M((?:[ \t]+(?:<[^\s<>`]+>|[^\s`|;&#)<>])+)+)")
# docs shorten `bin/workbench do snapshots <id>` to `do snapshots <id>` after the first mention
SHORT = re.compile(r"^\s*((?:do|cf|ploi|gcp|keys|monitor|addon|env|net|server|web)[ \t]+[a-z][a-z0-9-]*(?:[ \t]+(?:<[^\s<>`]+>|[^\s`|;&#)<>])+)*)\s*$")
REMOTE = re.compile(r"remote-run(?:\.sh)?\b[^`]*?[ \t]--[ \t]+([^`#<(]+)")
FENCE = re.compile(r"^\s*(```|~~~)")
PHP = {"do", "digitalocean", "cf", "cloudflare", "ploi", "gcp", "gcloud", "keys", "health", "credentials", "creds"}
SCRIPT = {"env": "env/env.sh", "addon": "addons/addon.sh", "addons": "addons/addon.sh",
          "monitor": "monitor/monitor.sh", "status": "server/status.sh"}
PY = {"configure", "profile", "plans", "py", "python"}
TOP = {"list", "help", "--help", "-h", "version", "--version", "php"} | PHP | set(SCRIPT) | PY
_cache = {}

def helptext(argv):
    key = tuple(argv)
    if key not in _cache:
        env = dict(os.environ, NO_COLOR="1", VSW_DOCS_CHECK="1")
        try:
            r = subprocess.run(argv, cwd=root, env=env, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
            _cache[key] = r.stdout + r.stderr
        except (OSError, subprocess.TimeoutExpired) as e:
            _cache[key] = ""
            print(f"warn: {' '.join(argv)}: {e}", file=sys.stderr)
    return _cache[key]

def is_word(t):
    return re.fullmatch(r"[a-z][a-z0-9-]*", t) is not None

def resolve(prog, args):
    """Return (label, help argv, remaining args) or (label, None, error)."""
    if prog.startswith("src/shell/lib/"):
        return prog, None, None          # sourced libraries, not commands
    if prog.startswith("src/shell/"):
        f = os.path.join(root, prog)
        if not os.path.isfile(f):
            return prog, None, "no such tool"
        return prog, ["bash", f, "--help"], args
    if not args:
        return "bin/workbench", None, None
    a = args[0]
    if a.startswith("<") or a.isupper() or a in ("...", "<area>"):
        return "bin/workbench", None, None
    if a in PHP:
        return f"bin/workbench {a}", [WB, "help", a], args[1:]
    if a in SCRIPT:
        return f"bin/workbench {a}", ["bash", os.path.join(root, "src/shell", SCRIPT[a]), "--help"], args[1:]
    if a in PY:
        sub = [a] if a not in ("py", "python") else []
        rest = args[1:]
        if a in ("py", "python", "profile") and rest and is_word(rest[0]):
            sub, rest = (sub + [rest[0]]), rest[1:]
            return f"bin/workbench {a} {sub[-1]}", [WB] + ([a] if a in ("py", "python") else []) + sub + ["--help"], ["--"] + rest
        return f"bin/workbench {a}", [WB, a, "--help"], ["--"] + rest
    if a in TOP:
        return f"bin/workbench {a}", None, None
    if os.path.isdir(os.path.join(root, "src/shell", a)) and (len(args) < 2 or not is_word(args[1])):
        return f"bin/workbench {a}", None, None   # "bin/workbench db <tool>": the area alone
    if len(args) < 2 or not is_word(args[1]):
        return f"bin/workbench {a}", None, "unknown command (not a top-level command or <area> <tool>)"
    area, tool = a, args[1]
    for cand in (f"src/shell/{area}/{tool}.sh", f"src/shell/{area}/{area}-{tool}.sh"):
        if os.path.isfile(os.path.join(root, cand)):
            return f"bin/workbench {area} {tool}", ["bash", os.path.join(root, cand), "--help"], args[2:]
    return f"bin/workbench {area} {tool}", None, f"no tool src/shell/{area}/{tool}.sh"

def check(prog, argstr):
    # a Markdown table writes alternatives as `do\|cf`: keep the first
    args = [t.split("\\|")[0].strip("\"'\\") for t in argstr.split()]
    label, hv, rest = resolve(prog, args)
    if hv is None:
        return [f"{label}: {rest}"] if isinstance(rest, str) else []
    text = helptext(hv)
    if not text.strip():
        return [f"{label}: --help printed nothing"]
    errs = []
    words = set(re.findall(r"[A-Za-z0-9][A-Za-z0-9_-]*", text))
    if rest and rest[0] == "--":          # subcommand already resolved (argparse sub-parser)
        rest = rest[1:]
    elif rest and is_word(rest[0]) and rest[0] not in words:
        errs.append(f"{label}: unknown subcommand '{rest[0]}'")
    for t in rest:
        m = re.fullmatch(r"(--[a-z][a-z0-9-]*)(=.*)?", t)
        if m and not re.search(re.escape(m.group(1)) + r"(?![a-z0-9-])", text):
            errs.append(f"{label}: unknown flag '{m.group(1)}'")
    return errs

_mgr = {}
def manager():
    """(commands from the dispatch `case`, help text) of the DB manager."""
    if not _mgr:
        src = open(os.path.join(root, MGR_PATH), encoding="utf-8").read()
        body = src[src.rindex('case "$CMD" in'):]
        cmds = set()
        for m in re.finditer(r"^\s+([a-z][a-z0-9|-]*)\)", body, re.M):
            cmds.update(m.group(1).split("|"))
        _mgr["cmds"], _mgr["help"] = cmds, helptext(["bash", os.path.join(root, MGR_PATH), "--help"])
    return _mgr["cmds"], _mgr["help"]

MGR_GLOBAL = {"--yes", "-y", "--non-interactive", "--config", "--quiet", "-q", "--version", "--help", "-h"}
def check_manager(argstr, label="manager"):
    args = [t.strip("\"'\\,") for t in argstr.split()]
    args = [a for a in args if a]
    while args and args[0] in MGR_GLOBAL:
        args = args[2:] if args[0] == "--config" else args[1:]
    if not args or not re.fullmatch(r"[a-z][a-z0-9-]*(\\\|[a-z|\\-]+)?", args[0]):
        return []    # a placeholder, a path or prose: not a command
    cmds, text = manager()
    sub = args[0].split("\\|")[0]
    if sub not in cmds:
        return [f"{label}: unknown manager command '{sub}'"]
    errs = []
    for t in args[1:]:
        m = re.fullmatch(r"(--[a-z][a-z0-9-]*)(=.*)?", t)
        if m and m.group(1) not in MGR_GLOBAL and not re.search(re.escape(m.group(1)) + r"(?![a-z0-9-])", text):
            errs.append(f"{label} {sub}: flag '{m.group(1)}' is not in the manager's --help")
    return errs

def check_remote(cmdlist):
    errs = []
    for part in cmdlist.split(","):
        part = part.strip().rstrip(".")
        if part and not part.startswith(("<", "...", "'")):
            errs += check_manager(part, "remote-run --")
    return errs

_php_help = {}
def php_rules(area):
    """(destructive command prefixes) for one PHP area, from its help."""
    if area not in _php_help:
        text = helptext([WB, "help", area])
        destr = []
        for line in text.splitlines():
            m = re.match(r"\s*workbench\s+(\S+)\s+((?:[a-z][a-z0-9-]*\s+)*)", line)
            if m and "destructive" in line:
                destr.append(" ".join([m.group(1)] + m.group(2).split()))
        _php_help[area] = destr
    return _php_help[area]

PHP_ALIAS = {"digitalocean": "do", "cloudflare": "cf", "gcloud": "gcp", "creds": "credentials"}
def check_php_extra(argstr):
    args = [t.split("\\|")[0].strip("\"'\\") for t in argstr.split()]
    if not args or args[0] not in PHP:
        return []
    area = PHP_ALIAS.get(args[0], args[0])
    errs, seen = [], set()
    for t in args:
        m = re.fullmatch(r"--([a-z][a-z0-9-]*)(=.*)?", t)
        if m:
            if m.group(1) in seen and m.group(1) not in ("json", "yes", "force", "dry-run"):
                errs.append(f"bin/workbench {area}: --{m.group(1)} given twice (the CLI rejects it; use a comma list)")
            seen.add(m.group(1))
    words = " ".join([area] + [a for a in args[1:] if is_word(a)])
    if "--force" not in args and "..." not in args and not any(a.startswith("<") and a.endswith(">...") for a in args):
        for d in php_rules(area):
            if (words + " ").startswith(d + " ") and len(args) > len(d.split()):
                errs.append(f"bin/workbench {d}: destructive, needs --force to run")
    return errs

def coverage(docs_text):
    """Every manager command, shell tool and PHP subcommand must be named in a doc."""
    errs = []
    cmds, _ = manager()
    for c in sorted(cmds - {"help", "-h", "--help", "apply"}):
        if not re.search(r"(?<![a-z0-9-])" + re.escape(c) + r"(?![a-z0-9-])", docs_text):
            errs.append(f"undocumented manager command '{c}'")
    for d, _, files in os.walk(os.path.join(root, "src/shell")):
        if d.endswith("/lib"):
            continue
        for f in files:
            a, t = os.path.basename(d), f[:-3]
            if f.endswith(".sh") and f not in docs_text and not re.search(rf"workbench {a} {t}(?![a-z0-9-])", docs_text):
                errs.append(f"undocumented shell tool src/shell/{os.path.basename(d)}/{f}")
    lines = [set(re.findall(r"[a-z0-9][a-z0-9-]*", ln)) for ln in docs_text.splitlines() if "workbench" in ln or "`" in ln]
    for area in ("do", "cf", "ploi", "gcp", "keys"):
        for line in helptext([WB, "help", area]).splitlines():
            m = re.match(r"\s*workbench\s+(\S+) ((?:[a-z][a-z0-9-]*(?: |$))+)", line)
            if not m:
                continue
            words = m.group(2).split()
            sub = " ".join(words[:2] if area in ("keys",) or words[0] in ("alerts", "uptime", "dns") and len(words) > 1 else words[:1])
            # on one doc line: the area and every word of the subcommand (tables write `account list/add/remove`)
            if not any(area in ws and all(w in ws for w in sub.split()) for ws in lines):
                errs.append(f"undocumented PHP command 'bin/workbench {area} {sub}'")
    return sorted(set(errs))

def commands(path):
    fenced = False
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if FENCE.match(line):
                fenced = not fenced
                continue
            if "vsw-commands: ignore" in line:
                continue
            spans = [line] if fenced else re.findall(r"`([^`]+)`", line)
            for s in spans:
                s = s.split(" #", 1)[0] if fenced else s
                for m in CMD.finditer(s):
                    if m.group(1) != MGR_PATH:
                        yield n, m.group(1), m.group(2)
                for m in MGR.finditer(s):
                    yield n, "M", m.group(1)
                if not fenced:
                    m = M_SPAN.match(s)
                    if m:
                        yield n, "M", m.group(1)
                    m = SHORT.match(s)
                    if m and not CMD.search(s):
                        yield n, "bin/workbench", " " + m.group(1)
                for m in REMOTE.finditer(s):
                    yield n, "REMOTE", m.group(1)

def self_test():
    """The checker must catch a wrong flag, subcommand and tool, and accept real ones."""
    cases = [("bin/workbench", " addon plan garage --bogus-flag", 1), ("bin/workbench", " addon frobnicate", 1),
             ("bin/workbench", " nosuch tool", 1), ("bin/workbench", " addon plan garage --role web", 0),
             ("bin/workbench", " env init --env prd --site x", 0), ("bin/workbench", " profile show dev-budget", 0),
             ("src/shell/web/check-db-reach.sh", " --remote web-1 10.0.0.5", 0),
             ("bin/workbench", " do alerts standard --email a@x --droplet 1 --droplet 2", 1),
             ("bin/workbench", " do alerts delete abc", 1), ("bin/workbench", " do alerts delete abc --force", 0),
             ("M", " frobnicate", 1), ("M", " engine disable mysql --dry-run", 0), ("M", " backup --bogus", 1),
             ("REMOTE", "verify, doctor, nosuch", 1), ("REMOTE", "upgrade --dry-run, cron-install", 0)]
    for prog, argstr, want in cases:
        got = len(check_manager(argstr) if prog == "M" else check_remote(argstr) if prog == "REMOTE"
                  else check(prog, argstr) + (check_php_extra(argstr) if prog == "bin/workbench" else []))
        if (got > 0) != (want > 0):
            print(f"check-commands self-test FAILED: {prog}{argstr} -> {got} problem(s)")
            return False
    return True

def main():
    if not self_test():
        return 1
    bad = total = 0
    docs_text = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", "vendor", "node_modules", "local", ".venv")]
        for f in sorted(files):
            if not f.endswith(".md"):
                continue
            p = os.path.join(d, f)
            if not os.path.relpath(p, root).startswith("CHANGELOG"):
                docs_text.append(open(p, encoding="utf-8").read())
            for n, prog, argstr in commands(p):
                total += 1
                if prog == "M":
                    found = check_manager(argstr)
                elif prog == "REMOTE":
                    found = check_remote(argstr)
                else:
                    if prog.endswith("remote-run.sh"):
                        argstr = argstr.split(" -- ", 1)[0]
                    found = check(prog, argstr) + (check_php_extra(argstr) if prog == "bin/workbench" else [])
                for e in found:
                    bad += 1
                    print(f"{os.path.relpath(p, root)}:{n}: {e}")
    for e in coverage("\n".join(docs_text)):
        bad += 1
        print(f"coverage: {e}")
    print(f"check-commands: {total} command(s) checked, {bad} problem(s)")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
