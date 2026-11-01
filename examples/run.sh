#!/usr/bin/env bash
# examples/run.sh - run an example offline: validate its settings with `workbench configure --dry-run`
# and print the plans of the tools it uses. Writes nothing, contacts no server, needs no secrets.
#
#   examples/run.sh <example>      e.g. examples/run.sh split-web-db-vpc
#   examples/run.sh --all          every example with an example.conf, then the catalog check (`make test`)
#   examples/run.sh --catalog      only the catalog check: runnable folders <-> "available" rows in README.md
#
# example.conf format (no secrets, ever; every password is generated on the server at install time):
#   PROFILE=<config/profiles name>
#   set KEY=VALUE          -> configure --set KEY=VALUE
#   plan <workbench args>  -> bin/workbench <args> (must be a read-only plan / --dry-run / --help)
#   appenv <stack>         -> examples/_shared/app-env.sh --self-test --stack <stack> (offline, throwaway files)
#   selftest <file>        -> bash examples/<example>/<file> --self-test (the example's own script, offline)
# A ploi-deploy.settings.sh is pasted into src/shell/deploy/ploi-deploy.sh and parsed (_shared/ploi-script.sh --check).
# Every file in the example folder also goes through tests/security/no-hardcoded-secrets.py.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$ROOT/bin/workbench"
SECRETS="$ROOT/tests/security/no-hardcoded-secrets.py"
CATALOG="$ROOT/examples/README.md"

run_one() {
  local name="$1" conf="$ROOT/examples/$1/example.conf" profile="" line args=() plans=() stacks=() tests=() out rc=0
  [ -f "$conf" ] || { echo "no $conf (status: planned?)" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      "") ;;
      PROFILE=*) profile="${line#PROFILE=}" ;;
      "set "*) args+=(--set "${line#set }") ;;
      "plan "*) plans+=("${line#plan }") ;;
      "appenv "*) stacks+=("${line#appenv }") ;;
      "selftest "*) tests+=("${line#selftest }") ;;
      *) echo "$conf: unknown line: $line" >&2; return 2 ;;
    esac
  done < "$conf"
  [ -n "$profile" ] || { echo "$conf: PROFILE= missing" >&2; return 2; }
  out="$(mktemp -d)"; trap 'rm -rf "$out"' RETURN
  echo "== $name: configure --profile $profile (dry run)"
  "$WB" configure --profile "$profile" --client "example-$name" --non-interactive --dry-run --out-dir "$out" "${args[@]}" || rc=$?
  [ "$rc" -eq 0 ] || { echo "== $name: configure checks failed (exit $rc)" >&2; return "$rc"; }
  local p
  for p in ${plans[@]+"${plans[@]}"}; do
    case " $p " in *" plan "*|*" --dry-run "*|*" --help "*|*" show "*|*" diff "*) ;; *) echo "$conf: refusing non-plan command: $p" >&2; return 2 ;; esac
    echo "== $name: workbench $p"
    # shellcheck disable=SC2086  # plan lines are word-split on purpose (no quoting in example.conf)
    "$WB" $p
  done
  for p in ${stacks[@]+"${stacks[@]}"}; do
    echo "== $name: app-env.sh --self-test --stack $p"
    bash "$ROOT/examples/_shared/app-env.sh" --self-test --stack "$p"
  done
  for p in ${tests[@]+"${tests[@]}"}; do
    case "$p" in */*|..*) echo "$conf: selftest takes a file in the example folder: $p" >&2; return 2 ;; esac
    echo "== $name: $p --self-test"
    bash "$ROOT/examples/$name/$p" --self-test
  done
  if [ -f "$ROOT/examples/$name/ploi-deploy.settings.sh" ]; then
    echo "== $name: ploi-deploy.sh with this SETTINGS block"
    bash "$ROOT/examples/_shared/ploi-script.sh" --check "$ROOT/examples/$name/ploi-deploy.settings.sh"
  fi
  if command -v python3 > /dev/null 2>&1; then
    echo "== $name: no hardcoded secrets"
    find "$ROOT/examples/$name" -type f -print0 | xargs -0 python3 "$SECRETS"
  fi
  echo "== $name: ok"
}

catalog_check() { # every runnable folder is "available" and linked in the catalog, and nothing else is
  local c n bad=0
  for c in "$ROOT"/examples/*/example.conf; do
    n="$(basename "$(dirname "$c")")"
    [ -f "$ROOT/examples/$n/README.md" ] || { echo "catalog: examples/$n has no README.md" >&2; bad=1; }
    grep -qE "^\| \[$n\]\($n/README\.md\) \|.*\| available \|\$" "$CATALOG" ||
      { echo "catalog: $n is runnable but not an 'available' row linking $n/README.md in examples/README.md" >&2; bad=1; }
  done
  while IFS= read -r n; do
    [ -f "$ROOT/examples/$n/example.conf" ] || { echo "catalog: $n is 'available' but examples/$n/example.conf is missing" >&2; bad=1; }
  done < <(sed -nE 's/^\| \[([a-z0-9-]+)\]\([a-z0-9-]+\/README\.md\) \|.*\| available \|$/\1/p' "$CATALOG")
  [ "$bad" -eq 0 ] && echo "ok   catalog (examples/README.md)"
  return "$bad"
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --all)
    fails=0
    for c in "$ROOT"/examples/*/example.conf; do
      n="$(basename "$(dirname "$c")")"
      if run_one "$n" > "/tmp/vsw-example-$n.log" 2>&1; then echo "ok   example $n"
      else echo "FAIL example $n (log: /tmp/vsw-example-$n.log)"; fails=$((fails + 1)); fi
    done
    catalog_check || fails=$((fails + 1))
    exit $((fails > 0)) ;;
  --catalog) catalog_check ;;
  *) run_one "$1" ;;
esac
