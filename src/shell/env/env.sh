#!/usr/bin/env bash
# =============================================================================
#  env.sh - create and check a Laravel .env per environment (values never shown)
# =============================================================================
#  init   Start from the existing .env (every value kept) or the template
#         (config/laravel.env.example), apply the environment's defaults,
#         generate APP_KEY when empty (never replaces one), take DB_* and
#         others from --from / --set, validate, show a KEY-ONLY diff, then
#         confirm, back up, write atomically with mode 600. On prd the write
#         needs the site (or "prd") typed; --yes is not enough.
#  check  Keys missing from / extra to the template, empty required values,
#         and the same validation rules. Exit 1 on an error.
#
#  USAGE
#    env.sh init  --env prd --site app.example.com --from db.env --url https://app.example.com
#    env.sh init  --env stg --path /home/ploi/stg.example.com --set MAIL_MAILER=smtp --dry-run
#    env.sh check --env prd --site app.example.com
#    env.sh check --path .env --against /tmp/other.env       keys only, both ways
#    env.sh init  --host web-1 --env prd --site app.example.com --from db.env
#         (--host copies this tool, the template and --from to the server over ssh; the
#          values travel as a file, never in argv, and the copy is removed afterwards)
#
#  OPTIONS
#    --env dev|stg|prd     --site DOMAIN (Ploi: DOMAIN-shared/.env, else DOMAIN/.env)
#    --path FILE|DIR       the .env (a dir means DIR/.env)   --template FILE
#    --from FILE           KEY=VALUE lines (e.g. `manager env` output)   --set KEY=VALUE (repeatable)
#    --url URL             APP_URL     --name NAME   APP_NAME
#    --against FILE        (check) compare keys with another .env instead of the template
#    --dry-run, -n  --yes, -y  --host H  -h, --help
#  Exit: 0 ok, 1 validation error, 2 usage, 3 not confirmed.
# =============================================================================
# SC2015: `test && ok || bad` is the idiom here (ok/bad never fail).
# shellcheck disable=SC2015
set -euo pipefail
TOOL="env"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
usage() { sed -n '2,/^# =====/{/^# =====/d;s/^#  \{0,1\}//;p;}' "$0"; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
case "$CMD" in init|check) ;; -h|--help|help|"") usage; exit 0 ;; *) CODE=2 die "usage: env.sh init|check [options] (see --help)" ;; esac
ENVN="" SITE="" TARGET="" TEMPLATE="" FROM="" URL="" NAME="" AGAINST="" HOST=""
SETS=()
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENVN="${2:?}"; shift 2 ;;
    --site) SITE="${2:?}"; shift 2 ;;
    --path) TARGET="${2:?}"; shift 2 ;;
    --template) TEMPLATE="${2:?}"; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --set) SETS+=("${2:?}"); shift 2 ;;
    --url) URL="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --against) AGAINST="${2:?}"; shift 2 ;;
    --dry-run|-n) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --host) HOST="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
case "$ENVN" in dev|stg|prd) ;; "") [ "$CMD" = check ] || CODE=2 die "--env dev|stg|prd is required" ;; *) CODE=2 die "--env must be dev, stg or prd" ;; esac
[[ -z "$SITE" || "$SITE" =~ ^[A-Za-z0-9.-]+$ ]] || CODE=2 die "bad --site: $SITE"
[ -n "$SITE" ] || [ -n "$TARGET" ] || CODE=2 die "give --site DOMAIN or --path FILE"
[[ -z "$URL" || "$URL" =~ ^https?://[A-Za-z0-9.:-]+(/.*)?$ ]] || CODE=2 die "--url must be http(s)://host[/path]"
[ -z "$TEMPLATE" ] && for t in "$HERE/../../../config/laravel.env.example" "$HERE/laravel.env.example"; do [ -f "$t" ] && { TEMPLATE="$t"; break; }; done

if [ -n "$HOST" ]; then # values go over as files, never as arguments
  [[ "$HOST" =~ ^[A-Za-z0-9@._:-]+$ ]] || CODE=2 die "bad --host"
  vals="$(mktemp)"; trap 'rm -f "$vals"' EXIT; chmod 600 "$vals"
  { [ -z "$FROM" ] || cat "$FROM"; for kv in "${SETS[@]+"${SETS[@]}"}"; do printf '%s\n' "$kv"; done; } > "$vals"
  rest=(); skip=0
  for a in "${ARGS[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in --host|--from|--set|--template|--against) skip=1; continue ;; esac; rest+=("$a")
  done
  rdir="$(ssh "$HOST" 'umask 077; mktemp -d')" || die "ssh $HOST failed"
  # shellcheck disable=SC2029
  ssh "$HOST" "mkdir -p '$rdir/env' '$rdir/lib'" || die "ssh $HOST failed"
  scp -q "$0" "$TEMPLATE" "$vals" "$HOST:$rdir/env/" || die "scp failed"
  scp -q "$HERE/../lib/common.sh" "$HOST:$rdir/lib/" || die "scp failed"
  scp -q "$HERE/../lib/progress.sh" "$HOST:$rdir/lib/" || die "scp failed"
  q=""; for a in "${rest[@]+"${rest[@]}"}"; do q+=" $(printf '%q' "$a")"; done
  [ -n "$AGAINST" ] && echo "note: --against is local only; ignored with --host" >&2
  # shellcheck disable=SC2029
  ssh -t "$HOST" "sudo bash '$rdir/env/env.sh' $CMD$q --template '$rdir/env/$(basename "$TEMPLATE")' --from '$rdir/env/$(basename "$vals")'; rc=\$?; rm -rf '$rdir'; exit \$rc"
  exit $?
fi

# ---- locate ------------------------------------------------------------------------------
if [ -z "$TARGET" ]; then
  TARGET="$R/home/ploi/$SITE/.env"; [ -d "$R/home/ploi/$SITE-shared" ] && TARGET="$R/home/ploi/$SITE-shared/.env"
fi
[ -d "$TARGET" ] && TARGET="$TARGET/.env"

keys_of() { sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$1" | awk '!s[$0]++'; }
get() { # get FILE KEY -> unquoted value without inline comment
  [ -f "$1" ] || return 0
  sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$2=//p" "$1" | tail -1 | awk -v q="'" '{
    v=$0
    if (v ~ /^"/) { sub(/^"/, "", v); sub(/"[[:space:]]*(#.*)?$/, "", v) }
    else if (substr(v, 1, 1) == q) { v = substr(v, 2); sub(q "[[:space:]]*(#.*)?$", "", v) }
    else { sub(/[[:space:]]+#.*$/, "", v); sub(/^#.*/, "", v); sub(/[[:space:]]+$/, "", v) }
    print v }'
}
put() { # put FILE KEY VALUE : replace the line in place (keeps comments/order) or append
  local q="$3"
  case "$q" in
    *\'*) q="\"$(printf '%s' "$q" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')\"" ;;   # double quotes, escaped
    *[[:space:]\#\"\$\\]*) q="'$q'" ;;                                                     # single quotes: no ${} expansion
  esac
  K="$2" V="$q" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]; done=0}
    { if (!done && $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "=") { print k "=" v; done=1 } else print }
    END{ if (!done) print k "=" v }' "$1" > "$1.vsw" && mv "$1.vsw" "$1"
}
private_ip() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|localhost$) ]]; }

validate() { # validate FILE : prints findings, never values
  local f="$1" e="$ENVN" v conn
  [ -n "$e" ] || case "$(get "$f" APP_ENV)" in production) e=prd ;; staging) e=stg ;; *) e=dev ;; esac
  v="$(get "$f" APP_KEY)"
  if [ -z "$v" ]; then bad "APP_KEY empty"
  elif [[ "$v" == base64:* ]] && [ "$(printf '%s' "${v#base64:}" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" != 32 ]; then bad "APP_KEY is not 32 bytes of base64"
  else ok "APP_KEY set"; fi
  local want=local; [ "$e" = stg ] && want=staging; [ "$e" = prd ] && want=production
  [ "$(get "$f" APP_ENV)" = "$want" ] && ok "APP_ENV=$want" || bad "APP_ENV is not $want"
  if [ "$e" != dev ]; then
    [ "$(get "$f" APP_DEBUG)" = false ] && ok "APP_DEBUG=false" || bad "APP_DEBUG must be false on $e"
    [[ "$(get "$f" APP_URL)" == https://* ]] && ok "APP_URL is https" || bad "APP_URL must be https on $e"
    [ "$(get "$f" SESSION_SECURE_COOKIE)" = true ] && ok "SESSION_SECURE_COOKIE=true" || warn "SESSION_SECURE_COOKIE should be true on $e"
  fi
  conn="$(get "$f" DB_CONNECTION)"
  if [ -n "$conn" ] && [ "$conn" != sqlite ]; then
    local h u; h="$(get "$f" DB_HOST)"; u="$(get "$f" DB_USERNAME)"
    [ -n "$(get "$f" DB_PASSWORD)" ] && ok "DB_PASSWORD set" || { if [ "$e" = dev ]; then warn "DB_PASSWORD empty"; else bad "DB_PASSWORD empty on $e"; fi; }
    case "$u" in root|postgres|sa|admin) bad "DB_USERNAME is a superuser ($u); use the per-env app user" ;; "") bad "DB_USERNAME empty" ;; *) ok "DB_USERNAME is an app user" ;; esac
    [ -n "$h" ] && [ "$e" != dev ] && ! private_ip "$h" && warn "DB_HOST is not a private address; use the VPC IP"
    [ "$conn" = pgsql ] && [ "$(get "$f" DB_PORT)" = 5432 ] && [ "$e" = prd ] && warn "DB_PORT 5432 is Postgres direct; PgBouncer (6432) is usual for the app"
  fi
  [ "$e" = prd ] && [ "$(get "$f" MAIL_MAILER)" = log ] && warn "MAIL_MAILER=log on prd: no mail is sent"
  [ "$e" = prd ] && [ "$(get "$f" LOG_LEVEL)" = debug ] && warn "LOG_LEVEL=debug on prd"
  grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$f" | cut -d= -f1 | cut -d: -f2 | sort | uniq -d | while read -r k; do warn "duplicate key $k (the last one wins)"; done
  return 0
}

# ---- check ---------------------------------------------------------------------------------
if [ "$CMD" = check ]; then
  [ -f "$TARGET" ] || die "$TARGET not found"
  ref="${AGAINST:-$TEMPLATE}"; [ -f "$ref" ] || die "no template (pass --template FILE)"
  say "env check $TARGET (keys vs $( [ -n "$AGAINST" ] && echo "$AGAINST" || echo template)):"
  missing="$(comm -23 <(keys_of "$ref" | sort) <(keys_of "$TARGET" | sort) | tr '\n' ' ')"
  extra="$(comm -13 <(keys_of "$ref" | sort) <(keys_of "$TARGET" | sort) | tr '\n' ' ')"
  [ -z "$missing" ] && ok "no missing keys" || warn "missing: $missing"
  [ -z "$extra" ] && ok "no extra keys" || say "  info  extra (not in the reference): $extra"
  mode="$(stat -c %a "$TARGET" 2>/dev/null || stat -f %Lp "$TARGET")"
  [ "$mode" = 600 ] || [ "$mode" = 640 ] || [ "$mode" = 400 ] && ok "mode $mode" || bad "mode $mode (want 600)"
  [ -n "$AGAINST" ] || validate "$TARGET"
  summary; exit $(( c_fail > 0 ? 1 : 0 ))
fi

# ---- init ------------------------------------------------------------------------------------
[ -f "$TEMPLATE" ] || [ -f "$TARGET" ] || die "no template found (pass --template FILE)"
WORK="$(mktemp)"; chmod 600 "$WORK"; trap 'rm -f "$WORK" "$WORK.vsw"' EXIT
if [ -f "$TARGET" ]; then cp "$TARGET" "$WORK"; base="existing $TARGET"; else cp "$TEMPLATE" "$WORK"; base="template"; fi
# env defaults (only where the value is a dev default or empty; your own values win)
case "$ENVN" in
  prd) put "$WORK" APP_ENV production; put "$WORK" APP_DEBUG false; put "$WORK" SESSION_SECURE_COOKIE true
       [ "$(get "$WORK" LOG_LEVEL)" = debug ] || [ -z "$(get "$WORK" LOG_LEVEL)" ] && put "$WORK" LOG_LEVEL error ;;
  stg) put "$WORK" APP_ENV staging; put "$WORK" APP_DEBUG false; put "$WORK" SESSION_SECURE_COOKIE true
       [ "$(get "$WORK" LOG_LEVEL)" = debug ] || [ -z "$(get "$WORK" LOG_LEVEL)" ] && put "$WORK" LOG_LEVEL warning ;;
  dev) put "$WORK" APP_ENV local ;;
esac
[ -z "$URL" ] || put "$WORK" APP_URL "$URL"
[ -z "$NAME" ] || put "$WORK" APP_NAME "$NAME"
add_kv() {
  local kv="${1%$'\r'}" k v
  [[ "$kv" =~ ^[[:space:]]*(#|$) ]] && return 0
  k="${kv%%=*}"; v="${kv#*=}"
  [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || CODE=2 die "bad key in --from/--set: $k"
  [[ "$v" != *$'\n'* ]] || CODE=2 die "$k: multi-line values are not supported"
  v="$(printf '%s' "$v" | sed -E 's/^"(.*)"$/\1/')"
  [ "$k" = APP_KEY ] && [ -n "$(get "$WORK" APP_KEY)" ] && { warn "APP_KEY already set - kept (rotate deliberately, not here)"; return 0; }
  put "$WORK" "$k" "$v"
}
if [ -n "$FROM" ]; then [ -r "$FROM" ] || die "cannot read $FROM"; while IFS= read -r line || [ -n "$line" ]; do add_kv "$line"; done < "$FROM"; fi
for kv in "${SETS[@]+"${SETS[@]}"}"; do add_kv "$kv"; done
gen=""
if [ -z "$(get "$WORK" APP_KEY)" ]; then
  have openssl || die "openssl is needed to generate APP_KEY"
  put "$WORK" APP_KEY "base64:$(openssl rand -base64 32)"; gen="APP_KEY"
fi

say "env init $TARGET ($ENVN, from the $base):"
added="$(comm -13 <( [ -f "$TARGET" ] && keys_of "$TARGET" | sort ) <(keys_of "$WORK" | sort) | tr '\n' ' ')"
changed=""
if [ -f "$TARGET" ]; then for k in $(keys_of "$WORK"); do [ "$(get "$TARGET" "$k")" = "$(get "$WORK" "$k")" ] || changed+="$k "; done; fi
[ -f "$TARGET" ] || added="(new file: $(keys_of "$WORK" | grep -c .) keys)"
say "  + added:   ${added:-none}"
say "  ~ changed: ${changed:-none}"
[ -z "$gen" ] || say "  * generated: $gen (value not shown)"
validate "$WORK"
if [ "$c_fail" -gt 0 ]; then summary; say "fix the errors above (use --set KEY=VALUE or --from FILE); nothing written"; exit 1; fi
if [ -f "$TARGET" ] && cmp -s "$WORK" "$TARGET"; then summary; say "no change"; exit 0; fi
if [ "$DRY" = 1 ]; then summary; say "dry run - nothing written"; exit 0; fi
lock
if [ "$ENVN" = prd ]; then confirm "write the PRODUCTION .env" "${SITE:-prd}"; else confirm "write $TARGET"; fi
audit confirmed "file=$TARGET env=$ENVN added=${added// /,} changed=${changed// /,} generated=${gen:-none}"
mkdir -p "$(dirname "$TARGET")"
if [ -f "$TARGET" ]; then backup "$TARGET"; cat "$WORK" > "$TARGET"; else (umask 077; cp "$WORK" "$TARGET"); fi
chmod 600 "$TARGET"
owner="$(stat -c %U "$(dirname "$TARGET")" 2>/dev/null || true)"
[ -z "$R" ] && [ -n "$owner" ] && [ "$(id -u)" -eq 0 ] && chown "$owner": "$TARGET"
ok "wrote $TARGET (mode 600)"
say "next: cd $(dirname "$TARGET") && php artisan config:cache   (and php artisan migrate --force on a deploy)"
audit succeeded "file=$TARGET"
