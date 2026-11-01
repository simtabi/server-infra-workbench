#!/usr/bin/env bash
# sweep.sh - find (and with --yes delete) anything a live test left behind: droplets that carry
# BOTH the vswlt- name prefix and the vsw-livetest tag; firewalls, ssh keys, VPCs and Spaces
# keys named vswlt-*, and empty vsw-livetest* tags. A teardown that ran normally leaves nothing; this is for a killed run
# (laptop asleep, network gone). Never touches anything without the prefix (and, for droplets, the tag).
# Spaces buckets: doctl cannot list them, so --buckets makes a throwaway full-access Spaces key
# (vswlt-sweep-*), lists the buckets in every Spaces region over the S3 API, deletes vswlt-* buckets
# (with --yes), then deletes that key. It reports how many buckets the account has in all: with none,
# the Spaces subscription ($5/month) is over. Usage: sweep.sh [--buckets] [--yes]
# shellcheck disable=SC2015
set -euo pipefail
yes=0 buckets=0
for a in "$@"; do case "$a" in --yes) yes=1 ;; --buckets) buckets=1 ;; *) echo "usage: sweep.sh [--buckets] [--yes]" >&2; exit 2 ;; esac; done
cd "$(dirname "$0")/../.."
command -v doctl >/dev/null && command -v jq >/dev/null || { echo "needs doctl and jq" >&2; exit 2; }
P=vswlt- T=vsw-livetest found=0
sp_del() { doctl spaces keys delete "$1" </dev/null; }   # no --force flag; does not prompt without a terminal
act() { # kind id name delete-command...
  local k="$1" id="$2" n="$3"; shift 3; found=$((found + 1))
  if [ "$yes" = 1 ]; then "$@" >/dev/null && echo "deleted $k $n" || echo "!! could not delete $k $n" >&2
  else echo "would delete $k $n"; fi
}
while read -r id n; do [ -n "$id" ] && act droplet "$id" "$n" doctl compute droplet delete "$id" --force; done \
  < <(doctl compute droplet list -o json | jq -r --arg p "$P" --arg t "$T" '.[] | select((.name | startswith($p)) and ((.tags // []) | index($t))) | "\(.id) \(.name)"')
[ "$yes" = 1 ] && [ "$found" -gt 0 ] && sleep 30   # VPCs empty out only after their droplets are gone
while read -r id n; do [ -n "$id" ] && act firewall "$id" "$n" doctl compute firewall delete "$id" --force; done \
  < <(doctl compute firewall list -o json | jq -r --arg p "$P" '.[] | select(.name | startswith($p)) | "\(.id) \(.name)"')
while read -r id n; do [ -n "$id" ] && act ssh-key "$id" "$n" doctl compute ssh-key delete "$id" --force; done \
  < <(doctl compute ssh-key list -o json | jq -r --arg p "$P" '.[] | select(.name | startswith($p)) | "\(.id) \(.name)"')
while read -r id n; do [ -n "$id" ] && act vpc "$id" "$n" doctl vpcs delete "$id" --force; done \
  < <(doctl vpcs list -o json | jq -r --arg p "$P" '.[] | select((.name | startswith($p)) and (.default | not)) | "\(.id) \(.name)"')
while read -r id n; do [ -n "$id" ] && act spaces-key "$id" "$n" sp_del "$id"; done \
  < <(doctl spaces keys list -o json 2>/dev/null | jq -r --arg p "$P" '.[]? | select(.name | startswith($p)) | "\(.access_key) \(.name)"')
while read -r t; do [ -n "$t" ] && act tag "$t" "$t" doctl compute tag delete "$t" --force; done \
  < <(doctl compute tag list -o json | jq -r --arg t "$T" '.[] | select((.name == $t or (.name | startswith($t + "-"))) and (.resources.count // 0) == 0) | .name')
if [ "$buckets" = 1 ]; then
  # shellcheck source=tests/live/lib/spaces.sh
  . tests/live/lib/spaces.sh
  SP_W="$(mktemp -d "${TMPDIR:-/tmp}/vswlt-sweep.XXXXXX")"; chmod 700 "$SP_W"
  trap 'sp_key_delete "$SP_W/k.env" 2>/dev/null; rm -rf "$SP_W"' EXIT
  sp_key_create "vswlt-sweep-$(openssl rand -hex 3)" 'bucket=;permission=fullaccess' "$SP_W/k.env" || { echo "!! could not create the throwaway Spaces key" >&2; exit 1; }
  for _ in $(seq 1 12); do sp_buckets "$SP_W/k.env" nyc3 >/dev/null && break; sleep 5; done   # new keys take a few seconds
  total=0 failed=""
  for r in $SP_REGIONS; do
    sp_buckets "$SP_W/k.env" "$r" > "$SP_W/b" || { failed="$failed $r"; continue; }
    total=$((total + $(grep -c . "$SP_W/b" || true)))
    while IFS= read -r b; do case "$b" in vswlt-*) found=$((found + 1))
      if [ "$yes" = 1 ]; then sp_bucket_purge "$SP_W/k.env" "$r" "$b" && { echo "deleted bucket $b ($r)"; total=$((total - 1)); } || echo "!! could not delete bucket $b ($r)" >&2
      else echo "would delete bucket $b ($r)"; fi ;; esac; done < "$SP_W/b"
  done
  echo "Spaces buckets in the account: $total$( [ "$total" = 0 ] && echo ' (none: no Spaces subscription is running)')${failed:+; could not list:$failed}"
fi
if [ "$found" = 0 ]; then echo "nothing left by live tests"; elif [ "$yes" = 0 ]; then echo "dry run: re-run with --yes to delete these $found"; fi
