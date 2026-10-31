#!/usr/bin/env bash
# Render every ```mermaid block in the Markdown docs with mermaid-cli, to prove they parse.
# Output: ${OUT:-/tmp/vsw-mermaid}/<file>-<n>.svg. Needs node/npx (network on first run).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${OUT:-/tmp/vsw-mermaid}"
rm -rf "$OUT"; mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import os, re, sys
out = sys.argv[1]
for d, dirs, files in os.walk("."):
    dirs[:] = [x for x in dirs if x not in (".git", "node_modules")]
    for f in files:
        if not f.endswith(".md"):
            continue
        p = os.path.join(d, f)
        base = p[2:-3].replace("/", "_")
        for i, b in enumerate(re.findall(r"```mermaid\n(.*?)```", open(p).read(), re.S), 1):
            open(os.path.join(out, f"{base}-{i}.mmd"), "w").write(b)
PY
n=0
for m in "$OUT"/*.mmd; do
  [ -e "$m" ] || { echo "no mermaid blocks found"; exit 1; }
  npx -y @mermaid-js/mermaid-cli -q -i "$m" -o "${m%.mmd}.svg" || { echo "FAILED: $m"; exit 1; }
  echo "mermaid ok  $(basename "$m")"; n=$((n+1))
done
echo "rendered $n diagrams to $OUT"
