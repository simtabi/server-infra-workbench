#!/usr/bin/env bash
# examples/gcp-vm/gcp-firewall.sh - the VPC firewall rules for the web + DB VMs, by network tag. Prints the
# gcloud commands; --apply runs them (needs gcloud logged in, roles/compute.securityAdmin).
#
#   gcp-firewall.sh [--network siw] [--project P] [--web-tag siw-web] [--db-tag siw-db] [--apply]
#   gcp-firewall.sh --self-test        offline: the plan has the rules it must and none it must not
#
# Why tags, not IP ranges: a rule "DB ports from tag siw-web" follows the web VM through a re-create or a new
# internal IP; "from 10.128.0.0/20" also admits every other VM in the subnet. SSH comes only from Google's
# IAP range (gcloud compute ssh --tunnel-through-iap), so port 22 is never open to the internet.
set -euo pipefail
network=siw project="" web=siw-web db=siw-db apply=0
IAP=35.235.240.0/20                         # Google's IAP TCP forwarding range (fixed, documented by Google)
die() { printf 'gcp-firewall: %s\n' "$1" >&2; exit "${2:-1}"; }

plan() {
  local p=""; [ -z "$project" ] || p=" --project $project"
  echo "gcloud compute firewall-rules create siw-web-https --network $network$p --direction INGRESS --action allow --rules tcp:80,tcp:443 --source-ranges 0.0.0.0/0 --target-tags $web"
  echo "gcloud compute firewall-rules create siw-db-from-web --network $network$p --direction INGRESS --action allow --rules tcp:5432,tcp:6432 --source-tags $web --target-tags $db"
  echo "gcloud compute firewall-rules create siw-ssh-iap --network $network$p --direction INGRESS --action allow --rules tcp:22 --source-ranges $IAP --target-tags $web,$db"
}

self_test() {
  local out ok=0
  out="$(plan)"
  expect() { local what="$1"; shift; if "$@"; then ok=$((ok + 1)); else die "self-test: $what"; fi; }
  # shellcheck disable=SC2329  # called through expect
  has() { printf '%s\n' "$out" | grep -qE -- "$1"; }
  # shellcheck disable=SC2329
  lacks() { ! has "$1"; }
  expect "web 80/443 rule missing" has "siw-web-https .*--rules tcp:80,tcp:443 .*--target-tags siw-web$"
  expect "DB ports must come from the web tag only" has "siw-db-from-web .*--source-tags siw-web --target-tags siw-db$"
  expect "SSH must come from IAP only" has "siw-ssh-iap .*--source-ranges 35\\.235\\.240\\.0/20 "
  expect "a DB port is open to the internet" lacks "tcp:(5432|6432|3306).*0\\.0\\.0\\.0/0"
  expect "SSH is open to the internet" lacks "tcp:22.*0\\.0\\.0\\.0/0"
  expect "three rules" test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3
  echo "gcp-firewall self-test: ok ($ok checks)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --network) network="${2:?}"; shift 2 ;;
    --project) project="${2:?}"; shift 2 ;;
    --web-tag) web="${2:?}"; shift 2 ;;
    --db-tag) db="${2:?}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --self-test) self_test; exit 0 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done
for v in "$network" "$project" "$web" "$db"; do
  case "$v" in *[!a-z0-9-]*) die "names are lowercase letters, digits and dashes: $v" 2 ;; esac
done
if [ "$apply" -eq 0 ]; then plan; echo "# plan only: add --apply to run these" >&2; exit 0; fi
command -v gcloud > /dev/null || die "gcloud not installed"
plan | while IFS= read -r cmd; do
  echo "+ $cmd"
  # shellcheck disable=SC2086  # the plan is built from validated words above
  $cmd
done
