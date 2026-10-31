"""Read KEY=VALUE files (the format of config/*.env.example and Laravel .env)."""

from __future__ import annotations

import re
from pathlib import Path

_LINE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")


def parse(text: str) -> dict[str, str]:
    """Parse KEY=VALUE lines. Comments, blank lines and malformed lines are ignored.

    Quoted values keep their content; an unquoted value ends at an inline ` #` comment.
    """
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _LINE.match(line)
        if not m:
            continue
        key, raw = m.group(1), m.group(2)
        after = line.split("=", 1)[1]
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
            value = raw[1:-1]
        elif after[:1].isspace() and raw.startswith("#"):
            value = ""  # `KEY=   # note`: empty value with a comment (`KEY=#x` keeps "#x")
        else:
            value = re.split(r"\s+#", raw, maxsplit=1)[0].strip()
        values[key] = value
    return values


def load(path: str | Path) -> dict[str, str]:
    return parse(Path(path).read_text(encoding="utf-8"))
