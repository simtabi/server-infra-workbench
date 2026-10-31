#!/usr/bin/env python3
"""Fail when a Markdown table row has a different cell count than its header.

GitHub silently drops extra cells and pads missing ones, so a row appended to the
wrong table loses its last column without any warning. Escaped pipes (\\|) and
pipes inside code spans are not cell separators.
"""
import os
import re
import sys

SKIP = {".git", "vendor", "node_modules", "local", ".venv"}


def cells(line: str) -> int:
    s = re.sub(r"`[^`]*`", "x", line.strip())  # code spans may hold pipes
    s = s.replace("\\|", "x")
    s = s.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return s.count("|") + 1


def check(path: str) -> list:
    out, header, fence = [], None, False
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            header = None
            continue
        if fence:
            continue
        is_row = line.lstrip().startswith("|")
        if not is_row:
            header = None
            continue
        if header is None:
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if re.match(r"^\s*\|?\s*:?-{3,}", nxt):
                header = cells(line)
            continue
        n = cells(line)
        if n != header:
            out.append(f"{path}:{i + 1}: {n} cells, header has {header}")
    return out


def self_test() -> None:
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as t:
        t.write("| a | b |\n|---|---|\n| `x|y` | z \\| w |\n| 1 | 2 | 3 |\n")
    r = check(t.name)
    os.unlink(t.name)
    assert len(r) == 1 and ":4:" in r[0], r


def main() -> int:
    self_test()
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    problems, files = [], 0
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP]
        for name in fs:
            if name.endswith(".md"):
                files += 1
                problems += check(os.path.join(d, name))
    for p in problems:
        print(p)
    print(f"check-tables: {files} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
