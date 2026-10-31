#!/usr/bin/env python3
"""Check that every documented `bin/workbench ...` and `src/shell/<area>/<tool>.sh ...` command exists.

Why: docs drift silently. A renamed subcommand or flag keeps working in the README long after the
tool stopped accepting it, and the first person to notice is someone copying it onto a server.
This reads every Markdown file (code spans and fenced blocks), resolves the tool the same way
bin/workbench does, and checks the subcommand and every --flag against that tool's own --help.
Offline: only --help/help is run, never a real command.

Exit 1 on any unknown tool, subcommand or flag.   Usage: python3 tests/docs/check-commands.py [root]
Inline opt-out for a deliberate example of a wrong command: `<!-- vsw-commands: ignore -->` on the line.
"""
import os, re, subprocess, sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
WB = os.path.join(root, "bin", "workbench")
CMD = re.compile(r"(?:\./)?(bin/workbench|src/shell/[a-z0-9-]+/[a-z0-9-]+\.sh)((?:[ \t]+[^\s`|;&#)>]+)*)")
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
                    yield n, m.group(1), m.group(2)

def self_test():
    """The checker must catch a wrong flag, subcommand and tool, and accept real ones."""
    cases = [("bin/workbench", " addon plan garage --bogus-flag", 1), ("bin/workbench", " addon frobnicate", 1),
             ("bin/workbench", " nosuch tool", 1), ("bin/workbench", " addon plan garage --role web", 0),
             ("bin/workbench", " env init --env prd --site x", 0), ("bin/workbench", " profile show dev-budget", 0),
             ("src/shell/web/check-db-reach.sh", " --remote web-1 10.0.0.5", 0)]
    for prog, argstr, want in cases:
        got = len(check(prog, argstr))
        if (got > 0) != (want > 0):
            print(f"check-commands self-test FAILED: {prog}{argstr} -> {got} problem(s)")
            return False
    return True

def main():
    if not self_test():
        return 1
    bad = total = 0
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", "vendor", "node_modules", "local", ".venv")]
        for f in sorted(files):
            if not f.endswith(".md"):
                continue
            p = os.path.join(d, f)
            for n, prog, argstr in commands(p):
                total += 1
                for e in check(prog, argstr):
                    bad += 1
                    print(f"{os.path.relpath(p, root)}:{n}: {e}")
    print(f"check-commands: {total} command(s) checked, {bad} problem(s)")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
