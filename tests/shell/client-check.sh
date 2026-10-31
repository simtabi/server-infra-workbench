#!/usr/bin/env bash
# client-check.sh - fail when a client identifier appears in a tracked file (or, with --history,
# anywhere in git history: every blob and every commit message).
#
#   tests/shell/client-check.sh              tracked files of the working tree
#   tests/shell/client-check.sh --history    git log -p --all plus all commit messages
#
# Terms: .client-denylist at the repo root (ignored by git; one fixed string per line, # comments),
# or $CLIENT_DENYLIST. Without one, the generic .client-denylist.example terms are used so the check
# still runs in CI. Matching is case-insensitive. The term files themselves are never scanned.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
list="${CLIENT_DENYLIST:-$ROOT/.client-denylist}"
[ -f "$list" ] || list="$ROOT/.client-denylist.example"
terms="$(mktemp)"; trap 'rm -f "$terms"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$list" | sed 's/[[:space:]]*$//' >"$terms" || true
n="$(wc -l <"$terms" | tr -d ' ')"
[ "$n" -gt 0 ] || { echo "client-check: no terms in $list" >&2; exit 2; }

if [ "${1:-}" = "--history" ]; then
  hits="$( { git log -p --all --format='commit %H%n%an <%ae>%n%B' -- . ':(exclude).client-denylist.example' 2>/dev/null; git tag -l -n99; } | grep -inF -f "$terms" | head -50 || true)"
  where="git history"
else
  hits="$(git ls-files -z -- . ':(exclude).client-denylist.example' ':(exclude)src/php/vendor' | xargs -0 grep -inIF -f "$terms" -- 2>/dev/null | head -50 || true)"
  where="tracked files"
fi
if [ -n "$hits" ]; then
  echo "client-check: client identifiers found in $where:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "0 hits for $n term(s) from $(basename "$list") in $where"
