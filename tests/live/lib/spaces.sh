# shellcheck shell=bash
# tests/live/lib/spaces.sh - DigitalOcean Spaces helpers for the live tests and sweep.sh.
# Keys go into 600 files (OFFSITE_ACCESS_KEY / OFFSITE_SECRET_KEY) and are handed to curl on stdin
# (-K -), so no key ever shows up in argv, ps, output or logs. Needs SP_W (a 700 work dir), doctl, jq, curl.
# doctl has no bucket commands (only `spaces keys`), so buckets go through the S3 API with curl's SigV4.
export SP_REGIONS="nyc3 sfo2 sfo3 ams3 fra1 sgp1 syd1 blr1 lon1 tor1 atl1"

sp_key_create() { # name grants out-file
  doctl spaces keys create "$1" --grants "$2" -o json > "$SP_W/key.json"
  jq -r '(.[0] // .) | "OFFSITE_ACCESS_KEY=\(.access_key)\nOFFSITE_SECRET_KEY=\(.secret_key)"' "$SP_W/key.json" > "$3"
  rm -f "$SP_W/key.json"; chmod 600 "$3"
  grep -qE '^OFFSITE_ACCESS_KEY=[A-Za-z0-9]{10,}$' "$3" && grep -qE '^OFFSITE_SECRET_KEY=.{20,}$' "$3"
}
sp_ak() { sed -n 's/^OFFSITE_ACCESS_KEY=//p' "$1"; }
# `doctl spaces keys delete` has no --force; with stdin not a terminal it does not prompt
sp_key_delete() { doctl spaces keys delete "$(sp_ak "$1")" </dev/null >/dev/null 2>&1; }

sp_s3() { # creds-file method url [curl args]: SigV4 request, body in $SP_W/s3.body, prints the HTTP code
  local f="$1" m="$2" u="$3"; shift 3
  printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:us-east-1:s3"\n' "$(sp_ak "$f")" "$(sed -n 's/^OFFSITE_SECRET_KEY=//p' "$f")" \
    | curl -s -o "$SP_W/s3.body" -w '%{http_code}' -K - -X "$m" "$u" "$@"
}

sp_buckets() { # creds-file region: bucket names in that region, one per line (non-zero if the listing failed)
  [ "$(sp_s3 "$1" GET "https://$2.digitaloceanspaces.com/")" = 200 ] || return 1
  python3 -c 'import re,sys; [print(n) for n in re.findall(r"<Bucket><Name>(.*?)</Name>", open(sys.argv[1]).read())]' "$SP_W/s3.body"
}

sp_bucket_purge() { # creds-file region bucket: delete every object, then the bucket; 0 once HEAD says 404
  local f="$1" h="$2.digitaloceanspaces.com" b="$3" code k n _
  for _ in $(seq 1 50); do   # pages of up to 1000 keys
    code="$(sp_s3 "$f" GET "https://$h/$b?list-type=2&max-keys=1000")"
    [ "$code" = 404 ] && return 0
    [ "$code" = 200 ] || { echo "!! listing $b: HTTP $code" >&2; return 1; }
    n=0
    while IFS= read -r k; do [ -n "$k" ] || continue; n=$((n + 1)); sp_s3 "$f" DELETE "https://$h/$b/$k" >/dev/null || true
    done < <(python3 -c '
import re, sys, urllib.parse, html
for k in re.findall(r"<Key>(.*?)</Key>", open(sys.argv[1]).read()):
    print(urllib.parse.quote(html.unescape(k), safe="/"))' "$SP_W/s3.body")
    [ "$n" = 0 ] && break
  done
  code="$(sp_s3 "$f" DELETE "https://$h/$b")"
  case "$code" in 204|404) ;; *) echo "!! deleting bucket $b: HTTP $code" >&2; return 1 ;; esac
  [ "$(sp_s3 "$f" HEAD "https://$h/$b" -I)" = 404 ]
}
