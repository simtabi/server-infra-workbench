#!/usr/bin/env bash
# run-suites.sh SUITE... - run test suites one after another with [i/n] progress, elapsed time and a
# summary table at the end (used by `make it`). Every suite runs even after a failure, so one red suite
# doesn't hide the state of the others; the exit code is 1 when any failed.
#   ONLY=wg-it,pitr-it make it     run just these suites (names without .sh)
# Leak guard: containers, networks and volumes named vsw* that a suite created and did not remove fail that
# suite and are removed, so one suite's leftovers (a network holding a fixed subnet) can't break the next one.
# Only vsw* names are watched: other projects and Kubernetes on the same Docker are never touched. With
# SIW_IT_PREFIX=vswb only vswb-* / vswb_* names are watched, so a parallel run's objects are left alone.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
# shellcheck source=tests/shell/it-lib.sh
. tests/shell/it-lib.sh
OWN="$(it_own)"
# shellcheck source=src/shell/lib/progress.sh
. src/shell/lib/progress.sh
suites=(); for s in "$@"; do n="$(basename "$s" .sh)"; [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$n,"* ]] && suites+=("$s"); done
[ "${#suites[@]}" -gt 0 ] || { echo "no suites selected (ONLY=${ONLY:-})" >&2; exit 2; }
docker_state() { # one line per test object (vsw* names only): kind name
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
  { docker ps -a --format 'container {{.Names}}'; docker network ls --format 'network {{.Name}}'; docker volume ls --format 'volume {{.Name}}'; } \
    | awk -v re="$OWN" '$2 ~ re' || true
}
leaks() { comm -13 <(printf '%s\n' "$1" | sort) <(docker_state | sort) | grep . || true; }
remove_leaks() { local k n; while read -r k n; do
  case "$k" in container) docker rm -f "$n" ;; network) docker network rm "$n" ;; volume) docker volume rm "$n" ;; esac >/dev/null 2>&1 || true
done < <(printf '%s\n' "$1" | sort); }  # sorted: containers, then networks, then volumes
[ "$SIW_IT_PREFIX" = vsw ] || echo "run prefix $SIW_IT_PREFIX, port offset $SIW_IT_PORT_OFFSET"
pre="$(docker_state)"; [ -z "$pre" ] || { echo "note: $SIW_IT_PREFIX* objects exist before the run (an aborted earlier run?):"; printf '%s\n' "$pre" | sed 's/^/  /'; }
PROGRESS_TOTAL=${#suites[@]}; rows=(); failed=0
for s in "${suites[@]}"; do
  progress_step "$(basename "$s" .sh)"; t0=$(date +%s); before="$(docker_state)"
  if bash "$s"; then r=ok; else r=FAIL; failed=1; fi
  left="$(leaks "$before")"
  if [ -n "$left" ]; then
    echo "LEAK: $(basename "$s" .sh) left these behind (removed now):"; printf '%s\n' "$left" | sed 's/^/  /'
    remove_leaks "$left"; r=LEAK; failed=1
  fi
  rows+=("$(printf '  %-4s %-16s %s' "$r" "$(basename "$s" .sh)" "$(progress_fmt $(($(date +%s) - t0)))")")
done
printf '\nsuites (%s total):\n' "$(progress_fmt $(($(date +%s) - PROGRESS_T0)))"; printf '%s\n' "${rows[@]}"
exit "$failed"
