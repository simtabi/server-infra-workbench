#!/usr/bin/env bash
# examples/cloudflare-dns-proxy/cf-dns.sh - apply records.txt to Cloudflare with `bin/workbench cf dns upsert`.
#
#   cf-dns.sh [records.txt]             print the commands (offline; nothing is sent)
#   cf-dns.sh --check [records.txt]     run them with --dry-run (reads the zone, shows each change, writes nothing)
#   cf-dns.sh --yes [records.txt]       write (upsert: unchanged records are a no-op)
#   cf-dns.sh realip                    print the Nginx real_ip snippet from Cloudflare's published ranges
#   cf-dns.sh --self-test               offline
#
# Why a checked file: one wrong orange cloud breaks things quietly. A proxied MX or SSH name stops working;
# a proxied or published DB or private address hands an attacker the origin. So the rules live in code:
# only A/AAAA/CNAME may be proxied, names starting with ssh-/db-/mail-/mx- and MX/TXT/SRV records are always
# DNS-only, and a private (RFC 1918) address or a db-* name is refused outright.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'cf-dns: %s\n' "$1" >&2; exit "${2:-1}"; }

private_ip() { case "$1" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*|fd*|fc*) return 0 ;; esac; return 1; }

records() { # records file -> validated TSV: zone type name content proxied(0|1) comment; exit 1 on a broken rule
  local f="$1" n=0 zone type name content mode comment label px
  while read -r zone type name content mode comment || [ -n "$zone" ]; do
    n=$((n + 1))
    case "$zone" in ""|"#"*) continue ;; esac
    [ -n "$mode" ] || die "$f:$n: want: zone type name content mode [comment]"
    case "$name" in "$zone"|*."$zone") ;; *) die "$f:$n: $name is not inside $zone" ;; esac
    label="${name%%.*}"
    case "$label" in db|db-*|postgres*|mysql*|redis*|pgbouncer*) die "$f:$n: $name: no DB names in public DNS (use the private IP)" ;; esac
    if private_ip "$content"; then die "$f:$n: $name -> $content: a private address in public DNS"; fi
    case "$mode" in
      proxied)
        case "$type" in A|AAAA|CNAME) ;; *) die "$f:$n: $type records can't be proxied" ;; esac
        case "$label" in ssh|ssh-*|mail|mail-*|mx|mx-*|smtp*|imap*|ftp*) die "$f:$n: $name must be DNS-only (not HTTP)" ;; esac
        px=1 ;;
      dns) px=0 ;;
      *) die "$f:$n: mode must be proxied or dns (got $mode)" ;;
    esac
    case "$type$zone$name$content" in *[!A-Za-z0-9.:-]*) die "$f:$n: unexpected characters in the record" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$zone" "$type" "$name" "$content" "$px" "${comment//$'\t'/ }"
  done < "$f"
}

args_of() { # one TSV line -> the upsert arguments, NUL-separated (no eval: the comment is data)
  local zone type name content px comment
  IFS=$'\t' read -r zone type name content px comment <<< "$1"
  printf '%s\0' cf dns upsert "$zone" "$type" "$name" "$content" --ttl 1
  [ "$px" = 0 ] || printf '%s\0' --proxied
  [ -z "$comment" ] || printf '%s\0' --comment "$comment"
}

commands() { # records file -> the commands, shell-quoted, for reading
  local line a out
  records "$1" > "$T.rec" || return 1
  while IFS= read -r line; do
    out="bin/workbench"
    while IFS= read -r -d '' a; do out="$out $(printf '%q' "$a")"; done < <(args_of "$line")
    echo "$out"
  done < "$T.rec"
}

realip() { # Cloudflare's ranges change rarely but do change: regenerate, never hand-edit
  local v4 v6
  v4="$(curl -fsS -m 10 https://www.cloudflare.com/ips-v4)" || die "could not fetch ips-v4"
  v6="$(curl -fsS -m 10 https://www.cloudflare.com/ips-v6)" || die "could not fetch ips-v6"
  echo "# /etc/nginx/snippets/cloudflare-realip.conf - generated $(date -u +%Y-%m-%d) by examples/cloudflare-dns-proxy/cf-dns.sh realip"
  printf '%s\n%s\n' "$v4" "$v6" | grep -E '^[0-9a-f:.]+/[0-9]+$' | sed 's/^/set_real_ip_from /; s/$/;/'
  echo "real_ip_header CF-Connecting-IP;"
}

self_test() {
  local ok=0 t out
  expect() { local what="$1"; shift; if "$@"; then ok=$((ok + 1)); else die "self-test: $what"; fi; }
  out="$(commands "$HERE/records.txt")"
  expect "four records" test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4
  expect "app not proxied" grep -q "upsert example.com A app.example.com 203.0.113.10 --ttl 1 --proxied" <<< "$out"
  expect "the ssh name is proxied" test "$(grep -c 'ssh-web-01.*--proxied' <<< "$out")" = 0
  expect "a comment is not one quoted word" grep -q 'comment web-01\\ \\(apex\\)$' <<< "$out"
  t="$T.bad"
  for bad in \
    "example.com A db-01.example.com 203.0.113.11 dns" \
    "example.com A app.example.com 10.0.0.6 proxied" \
    "example.com A app.example.com 203.0.113.10;id proxied" \
    "example.com MX example.com mx.example.net proxied" \
    "example.com A ssh.example.com 203.0.113.10 proxied" \
    "example.com A app.example.org 203.0.113.10 proxied" \
    "example.com A app.example.com 203.0.113.10 orange"; do
    echo "$bad" > "$t"
    if (commands "$t") > /dev/null 2>&1; then die "self-test: accepted: $bad"; else ok=$((ok + 1)); fi
  done
  echo "cf-dns self-test: ok ($ok checks)"
}

T="$(mktemp)"; trap 'rm -f "$T" "$T.rec" "$T.bad"' EXIT
mode=print
case "${1:-}" in
  --self-test) self_test; exit 0 ;;
  realip) realip; exit 0 ;;
  --check) mode=check; shift ;;
  --yes) mode=yes; shift ;;
  -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
file="${1:-$HERE/records.txt}"
[ -f "$file" ] || die "no $file" 2
if [ "$mode" = print ]; then
  commands "$file"; echo "# printed only: --check to preview against the zone, --yes to write" >&2; exit 0
fi
records "$file" > "$T.rec"
while IFS= read -r line; do
  args=()
  while IFS= read -r -d '' a; do args+=("$a"); done < <(args_of "$line")
  if [ "$mode" = yes ]; then args+=(--yes); else args+=(--dry-run); fi
  echo "+ bin/workbench ${args[*]}"
  "$ROOT/bin/workbench" "${args[@]}"
done < "$T.rec"
