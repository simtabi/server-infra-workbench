#!/usr/bin/env python3
"""no-hardcoded-secrets: fail on a password or secret written as a literal in a tracked file.

Rule (repo policy): passwords and secrets are generated at runtime (openssl rand, secrets.token_urlsafe,
random_bytes) or come from the environment (${VAR:?}). Tests, examples, docs and compose files included.
Docs use placeholders: <generated>, <password>, $(openssl rand -base64 24), "...".

What counts as a literal: a value after a secret-like key (PASSWORD, PASS, PWD, SECRET, TOKEN, API_KEY,
SECRET_KEY, ...) that is not empty, not a variable or command ($...), not a placeholder (<...>, ..., %s,
{{...}}) and not a path (for *_FILE keys). Also user:literal@ in URLs and mysql -p'literal'.
Values are never printed: findings show file, line, rule and the key only.

  python3 tests/security/no-hardcoded-secrets.py [--staged] [--self-test] [FILE...]
"""
import re
import subprocess
import sys

KEY = r"(?:[A-Za-z0-9_]*(?:PASSWORD|PASSWD|PASS|PWD|SECRET|TOKEN|API_?KEY|SECRET_?KEY|ACCESS_?KEY_?ID|PRIVATE_?KEY)[A-Za-z0-9_]*|password|passwd|secret|token|api_?key)"
# key = value, key: value, key => value, "key": "value", --password value, --password=value
ASSIGN = re.compile(r"""(?<![A-Za-z0-9_.{:-])["']?(?P<key>%s)["']?\s*(?P<op>=>|:=|=|:)\s*(?P<val>"[^"\n]*"|'[^'\n]*'|[^\s,;)\]}#]+)""" % KEY)
FLAG = re.compile(r"""--(?P<key>password|pass|secret|token|api-key)(?:=|\s+)(?P<val>"[^"\n]*"|'[^'\n]*'|[^\s;|&)]+)""")
URL = re.compile(r"""[a-z][a-z0-9+.-]*://(?P<key>[^\s/:@"'$]+):(?P<val>[^\s@/"']+)@""")
MYSQL_P = re.compile(r"""(?<![\w-])-p(?P<val>'[^'\n]+'|"[^"\n]+"|[A-Za-z0-9!#%^*+=_]{4,})(?=\s|$)""")

SAFE_VALUE = re.compile(r"""^(?:
      |\$.*|`.*|<.*|new|new\s.*|\{\$.*|\..*|[A-Za-z_][A-Za-z0-9_]*=.*|str|int|bool|float|bytes|string|\?string|Secret|Optional\[.*|\*+.*|\.\.\.|…|%[a-z0-9]*s.*|\{\{.*|\{%.*|\*+|x{3,}|X{3,}
    |true|false|null|none|None|yes|no|on|off|0|1|required|optional|auto|generated|redacted|<redacted>|\[redacted\]|REDACTED
    |[A-Za-z_][A-Za-z0-9_.]*\(.*|[A-Za-z_][A-Za-z0-9_]*\[.*|self\..*|this->.*|os\.environ.*|getenv.*|env\(.*|process\.env.*
    |/.*|\./.*|~/.*|[A-Za-z0-9_.-]+\.(?:txt|key|pem|crt|env|conf|json|yml|yaml|sh|pass|secret|cnf)
    |\\?\$\{.*|%\(.*|@.*|\#.*|-.*|\(.*|\[.*|\\.*|[A-Za-z_][A-Za-z0-9_:\\]*::.*
    |(?:hex|b64|base64|alnum|ak|gk|user|uuid)[0-9]*
)$""", re.X)
PROSE = re.compile(r"^[A-Za-z][A-Za-z0-9 ,./()'+-]*\s[A-Za-z0-9 ,./()'+-]*\s[A-Za-z0-9 ,./()'+-]*$")  # 2+ spaces, no symbols
KEY_SKIP = re.compile(r"(?:_FILE|_DIR|_PATH|_LEN|_LENGTH|_BYTES|_MIN|_MAX|_AGE|_TTL|_TYPE|_MODE|_ENV|_NAME|_HEADER|_URL|_USER|_ID_FILE|_REF|_SOURCE)$|^(?:pass|PASS)$", re.I)
WORDY = re.compile(r"^[a-z]+(?:[ -][a-z]+)+$")  # prose like "password: the one you typed"
SKIP_FILES = re.compile(r"(^|/)(?:composer\.lock|package-lock\.json|.*\.min\.js|.*\.phar|.*\.(?:png|jpg|gif|ico|pdf|gz|zip))$|^src/php/vendor/|^tests/security/no-hardcoded-secrets\.py$")


def unq(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    return v


def literal(v):
    v = v.replace('\\"', '"').replace("\\'", "'").replace("\\$", "$")
    v = unq(v).strip("'\"")
    if SAFE_VALUE.match(v) or WORDY.match(v) or PROSE.match(v):
        return False
    if re.fullmatch(r"[A-Z][A-Z0-9_]*", v):  # another variable name: PASS=PG_PASSWORD (indirection)
        return False
    return len(v) >= 3


def scan_text(path, text):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if "vsw-secrets: ignore" in line:  # only for scanner patterns and regexes, never for a real value
            continue
        line = line.replace("\\n", " ").replace("\\t", " ")  # printf 'A=1\nB=2' -> separate assignments
        for m in ASSIGN.finditer(line):
            if KEY_SKIP.search(m.group("key")):
                continue
            rest = line[m.end():]
            if m.group("val")[:1] in "'\"" and re.match(r"\s*[.+]\s*\S", rest):
                continue  # 'prefix_'.random_bytes(...) / "a" + gen(): a literal prefix joined to generated data
            if m.group("op") == ":" and m.group("val")[:1] not in "'\"" and re.match(r"\s+[a-z(]", rest):
                continue  # prose: "token: file or env", "password: the one ..."
            if literal(m.group("val")):
                out.append((path, n, "assign", m.group("key")))
        for m in FLAG.finditer(line):
            if literal(m.group("val")):
                out.append((path, n, "flag", "--" + m.group("key")))
        for m in URL.finditer(line):
            if literal(m.group("val")):
                out.append((path, n, "url-userinfo", m.group("key")))
        if re.search(r"\b(?:mysql|mysqladmin|mysqldump|mariadb[a-z-]*)\b", line):
            for m in MYSQL_P.finditer(line):
                if literal(m.group("val")):
                    out.append((path, n, "mysql -p", "-p"))
    return out


def tracked(staged):
    cmd = ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"] if staged else ["git", "ls-files"]
    return [f for f in subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.splitlines() if f]


def self_test():
    pw = "Zq" + "8vT" + "w2"  # assembled so the scanner source holds no literal
    bad = [f"DB_PASSWORD={pw}", f'"password": "{pw}"', f"postgres://app:{pw}@db:5432/app", f"mysql -uroot -p'{pw}' -e 1",
           f"--password {pw}", f"GRAFANA_ADMIN_PASSWORD: {pw}", f"AWS_SECRET_ACCESS_KEY={pw}x"]
    good = ["DB_PASSWORD=", 'DB_PASSWORD="$(openssl rand -hex 24)"', "PG_PASSWORD=${PG_PASSWORD:?set it}", "password: <generated>",
            "MONITOR_PG_PASSWORD_FILE=/root/.vsw-monitor.pass", "postgres://app:${PW}@db/app", "TARGET_PASSWORD=...",
            "--password-file /run/pw", "pw = secrets.token_urlsafe(24)", "MYSQL_PWD=\"$pw\" mysql -uroot", "repo1-cipher-pass=<redacted>",
            "PASSWORD: the one you typed at install"]
    fails = [b for b in bad if not scan_text("t", b)] + [g for g in good if scan_text("t", g)]
    for f in fails:
        print("self-test: wrong verdict for a case of shape:", re.sub(r"[A-Za-z0-9]", "x", f)[:60])
    return 1 if fails else 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    files = [a for a in argv if not a.startswith("--")] or tracked("--staged" in argv)
    hits = []
    for f in files:
        if SKIP_FILES.search(f):
            continue
        try:
            with open(f, encoding="utf-8", errors="strict") as fh:
                hits += scan_text(f, fh.read())
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
    for f, n, rule, key in hits:
        print(f"{f}:{n}: hardcoded secret ({rule}, key {key}); generate it at runtime or use a placeholder")
    print(f"no-hardcoded-secrets: {len(hits)} finding(s) in {len(files)} file(s)")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
