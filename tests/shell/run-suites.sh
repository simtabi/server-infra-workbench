#!/usr/bin/env bash
# run-suites.sh SUITE... - run test suites one after another with [i/n] progress, elapsed time and a
# summary table at the end (used by `make it`). Every suite runs even after a failure, so one red suite
# doesn't hide the state of the others; the exit code is 1 when any failed.
#   ONLY=wg-it,pitr-it make it     run just these suites (names without .sh)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
# shellcheck source=src/shell/lib/progress.sh
. src/shell/lib/progress.sh
suites=(); for s in "$@"; do n="$(basename "$s" .sh)"; [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$n,"* ]] && suites+=("$s"); done
[ "${#suites[@]}" -gt 0 ] || { echo "no suites selected (ONLY=${ONLY:-})" >&2; exit 2; }
PROGRESS_TOTAL=${#suites[@]}; rows=(); failed=0
for s in "${suites[@]}"; do
  progress_step "$(basename "$s" .sh)"; t0=$(date +%s)
  if bash "$s"; then r=ok; else r=FAIL; failed=1; fi
  rows+=("$(printf '  %-4s %-16s %s' "$r" "$(basename "$s" .sh)" "$(progress_fmt $(($(date +%s) - t0)))")")
done
printf '\nsuites (%s total):\n' "$(progress_fmt $(($(date +%s) - PROGRESS_T0)))"; printf '%s\n' "${rows[@]}"
exit "$failed"
