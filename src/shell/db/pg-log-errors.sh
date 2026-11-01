#!/usr/bin/env bash
# shellcheck disable=SC2016  # the remote script is single-quoted on purpose (it expands on the server)
# =============================================================================
#  pg-log-errors.sh - read-only Postgres/PgBouncer log check FROM YOUR WORKSTATION
# =============================================================================
#  Reads `docker logs` of the DB stack's postgres (or pgbouncer) container over
#  ssh and prints the same grouped, masked summary as the manager's
#  `log-errors` command. Installs nothing, needs no sudo when the login user is
#  in the docker group (falls back to `sudo -n docker`), changes nothing.
#  Background: docs/plan/postgres-log-quoting-errors.md
#
#  USAGE
#    pg-log-errors.sh --host db-alias [--since 24h|7d|all|YYYY-MM-DD] [--service postgres|pgbouncer]
#                     [--db-dir /opt/db]
#
#  EXIT
#    0 no errors in the window, 1 errors found, 2 usage / connection problem
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host="" since=24h svc=postgres dbdir=/opt/db
usage() { sed -n '3,18p' "$0" | sed 's/^#  \{0,1\}//'; }
while [ $# -gt 0 ]; do case "$1" in
  --host) host="${2:-}"; shift ;; --since) since="${2:-}"; shift ;; --service) svc="${2:-}"; shift ;;
  --db-dir) dbdir="${2:-}"; shift ;; -h|--help) usage; exit 0 ;;
  *) echo "pg-log-errors: unknown option: $1" >&2; usage >&2; exit 2 ;; esac; shift; done
[ -n "$host" ] || { echo "pg-log-errors: --host is required" >&2; exit 2; }
case "$svc" in postgres|pgbouncer) ;; *) echo "pg-log-errors: --service postgres or pgbouncer" >&2; exit 2 ;; esac
[[ "$dbdir" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "pg-log-errors: --db-dir must be an absolute path" >&2; exit 2; }
# shellcheck source=SCRIPTDIR/docker-db-server-manager.sh
DBM_CONFIG=/dev/null DBM_SOURCE_ONLY=1 source "$HERE/docker-db-server-manager.sh"
trap - ERR; set +e
ds="$(log_errors_since "$since")" || { echo "pg-log-errors: --since takes 30m, 24h, 7d, all or YYYY-MM-DD" >&2; exit 2; }
# the remote side is fixed text plus validated values, quoted with %q (no SQL, no user strings)
remote="$(printf 'svc=%q dir=%q ds=%q; ' "$svc" "$dbdir" "$ds")"
remote+='D=docker; $D ps >/dev/null 2>&1 || D="sudo -n docker"; '
remote+='c="$($D ps -aq --filter label=com.docker.compose.service=$svc --filter label=com.docker.compose.project.working_dir=$dir | head -n1)"; '
remote+='[ -n "$c" ] || c="$($D ps -aq --filter label=com.docker.compose.service=$svc | head -n1)"; '
remote+='[ -n "$c" ] || { echo "no $svc container" >&2; exit 3; }; '
remote+='if [ -n "$ds" ]; then $D logs --timestamps --since "$ds" "$c" 2>&1; else $D logs --timestamps "$c" 2>&1; fi'
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
ssh -o BatchMode=yes "$host" "$remote" > "$out" || { echo "pg-log-errors: could not read the $svc log on $host (ssh/docker access?)" >&2; exit 2; }
log_errors_summary "$host $svc, since $since" < "$out"
