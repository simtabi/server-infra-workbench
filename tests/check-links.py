#!/usr/bin/env python3
"""Check relative links and #anchors in every Markdown file (offline).

External http(s)/mailto links are skipped. Anchors use GitHub's heading slugs.
Exit 1 on any broken link.  Usage: python3 tests/check-links.py [root]
"""
import os, re, sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"^\s*(```|~~~)")

def slug(text):
    text = re.sub(r"`|\*\*|\*", "", text.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")

def scan(path):
    """Return (links, anchors) of a Markdown file, ignoring fenced code."""
    links, anchors, seen, fenced = [], set(), {}, False
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if FENCE.match(line):
                fenced = not fenced
                continue
            if fenced:
                continue
            m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
            if m:
                s = slug(m.group(1))
                k = seen.get(s, 0)
                anchors.add(s if k == 0 else f"{s}-{k}")
                seen[s] = k + 1
            for target in LINK.findall(re.sub(r"`[^`]*`", "", line)):
                links.append((n, target))
    return links, anchors

md = []
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x not in (".git", "node_modules")]
    md += [os.path.join(d, f) for f in files if f.endswith(".md")]

cache, bad, total = {}, 0, 0
def anchors_of(p):
    if p not in cache:
        cache[p] = scan(p)[1]
    return cache[p]

for f in sorted(md):
    for n, target in scan(f)[0]:
        if re.match(r"^[a-z]+:", target):
            continue
        total += 1
        path, _, frag = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        rel = os.path.relpath(f, root)
        if not os.path.exists(dest):
            print(f"BROKEN  {rel}:{n}  {target}  (no such file)"); bad += 1
        elif frag and dest.endswith(".md") and frag not in anchors_of(dest):
            print(f"BROKEN  {rel}:{n}  {target}  (no heading #{frag})"); bad += 1

print(f"links: {total} relative links in {len(md)} files, {bad} broken")
sys.exit(1 if bad else 0)
