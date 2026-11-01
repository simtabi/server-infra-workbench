#!/usr/bin/env bash
# examples/ha-two-web-lb/rolling-deploy.sh - deploy the web nodes one at a time; stop at the first that fails.
#
#   rolling-deploy.sh --domain app.example.com --sha <commit> web-01=<server-id>:<site-id> web-02=<server-id>:<site-id>
#   add --yes to deploy; without it this only prints the plan (nothing is sent)
#
# Why: deploying both at once means both run composer/npm at the same moment and both restart PHP; for a
# few seconds neither may pass the load balancer's health check. One at a time, the LB keeps sending traffic
# to the node that isn't deploying. A node counts as done when it serves /version = the commit (ssh to the
# node, curl on loopback with the site's Host header: the node itself, not whichever one the LB picks).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
yes=0 domain="" sha="" timeout=600 nodes=()
die() { printf 'rolling-deploy: %s\n' "$1" >&2; exit "${2:-1}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) yes=1; shift ;;
    --domain) domain="${2:?}"; shift 2 ;;
    --sha) sha="${2:?}"; shift 2 ;;
    --timeout) timeout="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *=*:*) nodes+=("$1"); shift ;;
    *) die "unknown argument: $1 (want NODE=SERVER_ID:SITE_ID)" 2 ;;
  esac
done
[ -n "$domain" ] && [ -n "$sha" ] && [ "${#nodes[@]}" -ge 1 ] || die "need --domain, --sha and at least one NODE=SERVER_ID:SITE_ID" 2
case "$sha" in *[!0-9a-f]*) die "--sha must be a full lowercase commit hash" 2 ;; esac
[ "${#sha}" -eq 40 ] || die "--sha must be the full 40-character commit (git rev-parse HEAD)" 2

served() { ssh -o BatchMode=yes "$1" "curl -fsS -m 5 -H 'Host: $domain' http://127.0.0.1/version" 2>/dev/null || true; }

for n in "${nodes[@]}"; do
  host="${n%%=*}" ids="${n#*=}"; server="${ids%%:*}" site="${ids#*:}"
  if [ "$yes" -eq 0 ]; then
    echo "plan: $host: bin/workbench ploi deploy $server $site, then wait until $host serves /version = ${sha:0:12} (max ${timeout}s)"
    continue
  fi
  [ "$(served "$host")" != "$sha" ] || { echo "$host: already on ${sha:0:12}, skipped"; continue; }
  echo "$host: deploying (server $server, site $site)"
  "$ROOT/bin/workbench" ploi deploy "$server" "$site" --yes
  start=$SECONDS
  until [ "$(served "$host")" = "$sha" ]; do
    [ $((SECONDS - start)) -lt "$timeout" ] || die "$host: not on ${sha:0:12} after ${timeout}s; stopped, later nodes untouched (Ploi -> Site -> Deployments)"
    sleep 10
  done
  echo "$host: on ${sha:0:12} after $((SECONDS - start))s"
done
[ "$yes" -eq 1 ] || echo "dry run: nothing sent (add --yes)"
