#!/usr/bin/env bash
# examples/_shared/with-env.sh - run a command with the KEY=VALUE lines of a .env file exported.
#
#   with-env.sh /home/ploi/app.example.com-shared/.env gunicorn config.wsgi ...
#
# For daemons that do not read .env themselves (Ploi daemons run under Supervisor, which has no env file).
# No eval and no shell expansion: a line is KEY=VALUE, KEY="VALUE" or KEY='VALUE'; comments and blanks skipped.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
f="$1"; shift
[ -r "$f" ] || { echo "with-env: cannot read $f" >&2; exit 1; }
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
  k="${BASH_REMATCH[2]}" v="${BASH_REMATCH[3]}"
  if [[ "$v" =~ ^\"(.*)\"$ ]] || [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
  export "$k=$v"
done < "$f"
exec "$@"
