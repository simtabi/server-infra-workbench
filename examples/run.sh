#!/usr/bin/env bash
# examples/run.sh - run an example offline: validate its settings with `workbench configure --dry-run`
# and print the plans of the tools it uses. Writes nothing, contacts no server, needs no secrets.
#
#   examples/run.sh <example>      e.g. examples/run.sh split-web-db-vpc
#   examples/run.sh --all          every example with an example.conf (what `make test` runs)
#
# example.conf format (no secrets, ever; every password is generated on the server at install time):
#   PROFILE=<config/profiles name>
#   set KEY=VALUE          -> configure --set KEY=VALUE
#   plan <workbench args>  -> bin/workbench <args> (must be a read-only plan / --dry-run / --help)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$ROOT/bin/workbench"

run_one() {
  local name="$1" conf="$ROOT/examples/$1/example.conf" profile="" line args=() plans=() out rc=0
  [ -f "$conf" ] || { echo "no $conf (status: planned?)" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      "") ;;
      PROFILE=*) profile="${line#PROFILE=}" ;;
      "set "*) args+=(--set "${line#set }") ;;
      "plan "*) plans+=("${line#plan }") ;;
      *) echo "$conf: unknown line: $line" >&2; return 2 ;;
    esac
  done < "$conf"
  [ -n "$profile" ] || { echo "$conf: PROFILE= missing" >&2; return 2; }
  out="$(mktemp -d)"; trap 'rm -rf "$out"' RETURN
  echo "== $name: configure --profile $profile (dry run)"
  "$WB" configure --profile "$profile" --client "example-$name" --non-interactive --dry-run --out-dir "$out" "${args[@]}" || rc=$?
  [ "$rc" -eq 0 ] || { echo "== $name: configure checks failed (exit $rc)" >&2; return "$rc"; }
  local p
  for p in "${plans[@]}"; do
    case " $p " in *" plan "*|*" --dry-run "*|*" --help "*|*" show "*|*" diff "*) ;; *) echo "$conf: refusing non-plan command: $p" >&2; return 2 ;; esac
    echo "== $name: workbench $p"
    # shellcheck disable=SC2086  # plan lines are word-split on purpose (no quoting in example.conf)
    "$WB" $p
  done
  echo "== $name: ok"
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --all) fails=0; for c in "$ROOT"/examples/*/example.conf; do n="$(basename "$(dirname "$c")")"; if run_one "$n" > "/tmp/vsw-example-$n.log" 2>&1; then echo "ok   example $n"; else echo "FAIL example $n (log: /tmp/vsw-example-$n.log)"; fails=$((fails + 1)); fi; done; exit $((fails > 0)) ;;
  *) run_one "$1" ;;
esac
