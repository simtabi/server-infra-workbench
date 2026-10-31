#!/usr/bin/env bash
# =============================================================================
#  diagnose.sh - why is this Laravel site broken? (Ploi / nginx / php-fpm)
# =============================================================================
#  Read-only by default: checks the site, its .env (values never printed),
#  the DB/Redis it points at, workers, scheduler, nginx, php-fpm, disk, TLS
#  and a local HTTP request. Each finding says why it matters.
#
#  --fix applies only the safe, reversible fixes (backups first):
#    .env mode 600 | APP_DEBUG=false outside dev | storage + bootstrap/cache
#    owned by the site user and writable | php artisan storage:link |
#    rebuild the config cache after an .env change.
#  It never generates APP_KEY, edits DB settings or restarts services.
#  On prd, --fix needs the site domain typed (no --yes shortcut).
#
#  USAGE
#    diagnose.sh --site app.example.com [--env prd]          on the web server
#    diagnose.sh --site app.example.com --fix --dry-run      show the fixes
#    diagnose.sh --host web-1 --site app.example.com --env prd --fix
#
#  OPTIONS
#    --site DOMAIN    Ploi site (default path /home/ploi/DOMAIN, uses ./current
#                     for zero-downtime sites, .env from DOMAIN-shared/ if present)
#    --path DIR       site root instead of the Ploi default   --owner USER (default: owner of DIR)
#    --env dev|stg|prd  expected environment (default: from APP_ENV)
#    --fix  --dry-run, -n  --yes, -y  --host H  --json-summary  -h, --help
#  Exit: 0 healthy, 1 a FAIL found, 2 usage, 3 fix not confirmed.
# =============================================================================
# SC2015: `test && ok || warn` is the idiom here (ok/warn never fail).
# shellcheck disable=SC2015
set -euo pipefail
TOOL=diagnose
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
usage() { sed -n '2,/^# =====/{/^# =====/d;s/^#  \{0,1\}//;p}' "$0"; }

SITE="" SITE_PATH="" OWNER="" ENVN="" FIX=0 HOST="" JSON=0
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --site) SITE="${2:?}"; shift 2 ;;
    --path) SITE_PATH="${2:?}"; shift 2 ;;
    --owner) OWNER="${2:?}"; shift 2 ;;
    --env) ENVN="${2:?}"; shift 2 ;;
    --fix) FIX=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --host) HOST="${2:?}"; shift 2 ;;
    --json-summary) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
[ -n "$SITE" ] || [ -n "$SITE_PATH" ] || CODE=2 die "give --site DOMAIN or --path DIR"
[[ -z "$SITE" || "$SITE" =~ ^[A-Za-z0-9.-]+$ ]] || CODE=2 die "bad --site: $SITE"
case "$ENVN" in ""|dev|stg|prd) ;; *) CODE=2 die "--env must be dev, stg or prd" ;; esac
if [ -n "$HOST" ]; then
  rest=(); skip_next=0
  for a in "${ARGS[@]}"; do if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi; [ "$a" = --host ] && { skip_next=1; continue; }; rest+=("$a"); done
  remote "$HOST" "$0" "${rest[@]+"${rest[@]}"}"; exit $?
fi

# ---- locate the site -----------------------------------------------------------------
[ -n "$SITE_PATH" ] || SITE_PATH="$R/home/ploi/$SITE"
APP="$SITE_PATH"; [ -d "$SITE_PATH/current" ] && APP="$SITE_PATH/current"
ENV_FILE="$APP/.env"; [ -n "$SITE" ] && [ -f "$R/home/ploi/$SITE-shared/.env" ] && ENV_FILE="$R/home/ploi/$SITE-shared/.env"
stat_fmt() { stat -c "$1" "$2" 2>/dev/null || stat -f "$(printf '%s' "$1" | sed 's/%a/%Lp/; s/%U/%Su/')" "$2" 2>/dev/null; }
[ -n "$OWNER" ] || OWNER="$(stat_fmt %U "$SITE_PATH" || echo ploi)"
envget() { [ -f "$ENV_FILE" ] || return 0; sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/[[:space:]]+#.*$//'; }
private_ip() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|localhost$) ]]; }
tcp() { if have nc; then nc -z -w 3 "$1" "$2" >/dev/null 2>&1; else timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; fi; }
as_owner() { if [ "$(id -un)" = "$OWNER" ] || [ -n "$R" ]; then "$@"; else sudo -u "$OWNER" -- "$@"; fi; }
FIXES=()
fixable() { FIXES+=("$1"); }

say "diagnose ${SITE:-$SITE_PATH} (app $APP, owner $OWNER):"
# -- files
if [ ! -d "$APP" ]; then bad "site dir $APP missing"; why "deploy once in Ploi, or pass --path"; summary; exit 1; fi
[ -f "$APP/artisan" ] && ok "Laravel app found" || warn "no artisan in $APP (not Laravel? wrong --path?)"
if [ ! -f "$ENV_FILE" ]; then bad ".env missing ($ENV_FILE)"; why "Laravel boots with defaults and fails on DB/APP_KEY; create it: workbench env init"
else
  mode="$(stat_fmt %a "$ENV_FILE")"
  if [ "$mode" = 600 ] || [ "$mode" = 640 ] || [ "$mode" = 400 ]; then ok ".env mode $mode"
  else warn ".env mode $mode (want 600)"; why ".env holds the DB password and APP_KEY"; fixable env_mode; fi
fi
appenv="$(envget APP_ENV)"; debug="$(envget APP_DEBUG)"; key="$(envget APP_KEY)"; url="$(envget APP_URL)"
if [ -z "$ENVN" ]; then case "$appenv" in production) ENVN=prd ;; staging) ENVN=stg ;; *) ENVN=dev ;; esac; fi
want_env=local; [ "$ENVN" = prd ] && want_env=production; [ "$ENVN" = stg ] && want_env=staging
if [ "$ENVN" = dev ] || [ "$appenv" = "$want_env" ]; then ok "APP_ENV=${appenv:-unset} ($ENVN)"
else warn "APP_ENV=${appenv:-unset} but this is $ENVN (want $want_env)"; why "config, logging and error pages key off APP_ENV"; fi
if [ "$ENVN" != dev ] && [ "$debug" = true ]; then bad "APP_DEBUG=true on $ENVN"; why "debug pages leak env values, SQL and stack traces to visitors"; fixable debug_off
else ok "APP_DEBUG=${debug:-unset}"; fi
if [ -z "$key" ]; then bad "APP_KEY empty"; why "sessions and encryption fail; generate ONCE per env: php artisan key:generate (never rotate blindly: encrypted data becomes unreadable)"
else ok "APP_KEY set (value not shown)"; fi
[ "$ENVN" = prd ] && [[ -n "$url" && "$url" != https://* ]] && warn "APP_URL is not https on prd" && why "mixed content, insecure cookies and wrong signed URLs"
for d in storage bootstrap/cache; do
  if [ ! -d "$APP/$d" ]; then bad "$d missing"; fixable perms; continue; fi
  o="$(stat_fmt %U "$APP/$d")"
  if [ "$o" != "$OWNER" ] && [ -z "$R" ]; then warn "$d owned by $o (want $OWNER)"; fixable perms
  elif ! as_owner test -w "$APP/$d"; then warn "$d not writable by $OWNER"; fixable perms
  else ok "$d writable by $OWNER"; fi
done
if [ -d "$APP/public" ] && [ -d "$APP/storage/app/public" ] && [ ! -e "$APP/public/storage" ]; then
  warn "public/storage link missing"; why "uploaded files 404"; fixable storage_link
fi
[ -f "$APP/bootstrap/cache/config.php" ] && [ -f "$ENV_FILE" ] && [ "$ENV_FILE" -nt "$APP/bootstrap/cache/config.php" ] \
  && warn ".env is newer than the config cache" && why "a cached config ignores .env changes until php artisan config:cache" && fixable config_cache

# -- services the app depends on
dbh="$(envget DB_HOST)"; dbp="$(envget DB_PORT)"; conn="$(envget DB_CONNECTION)"
if [ -n "$dbh" ] && [ "$conn" != sqlite ]; then
  [ -n "$dbp" ] || { [ "$conn" = pgsql ] && dbp=5432 || dbp=3306; }
  if tcp "$dbh" "$dbp"; then ok "DB $conn reachable at $dbh:$dbp"
  else bad "DB $dbh:$dbp not reachable"; why "check: the private IP (not the public one), PgBouncer is 6432 and Postgres 5432, the DO cloud firewall and ufw allow this web server, and the DB containers are up (manager status)"; fi
  [ "$ENVN" != dev ] && ! private_ip "$dbh" && warn "DB_HOST $dbh is not a private address" && why "DB traffic should stay on the VPC; public DB ports are an attack surface"
  [ "$(envget DB_USERNAME)" = root ] || [ "$(envget DB_USERNAME)" = postgres ] && bad "DB_USERNAME is a superuser" && why "use the per-env app user (manager create-user); see docs/reference/privileges.md"
fi
rh="$(envget REDIS_HOST)"
if [ -n "$rh" ]; then rp="$(envget REDIS_PORT)"; if tcp "$rh" "${rp:-6379}"; then ok "Redis reachable at $rh:${rp:-6379}"; else bad "Redis $rh:${rp:-6379} not reachable"; why "cache, sessions and queues using redis fail"; fi; fi
qc="$(envget QUEUE_CONNECTION)"
if [ -n "$qc" ] && [ "$qc" != sync ]; then
  if pgrep -f 'artisan (queue:work|horizon)' >/dev/null 2>&1; then ok "queue worker running ($qc)"
  else warn "QUEUE_CONNECTION=$qc but no queue:work/horizon process"; why "jobs pile up silently; add a daemon: workbench ploi daemon-create"; fi
fi
if [ -f "$APP/artisan" ]; then
  if crontab -l -u "$OWNER" 2>/dev/null | grep -q 'schedule:run'; then ok "scheduler in $OWNER's crontab"
  else warn "no schedule:run in $OWNER's crontab"; why "scheduled tasks (backups, pruning, reports) never run"; fi
fi
# -- web stack
if have nginx; then if nginx -t >/dev/null 2>&1; then ok "nginx -t"; else bad "nginx -t fails"; why "nginx will refuse to reload; run: sudo nginx -t"; fi; fi
if have systemctl; then
  fpm="$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*-fpm/{print $1; exit}' || true)"
  [ -n "$fpm" ] && ok "php-fpm running ($fpm)" || warn "no running php-fpm service"
fi
use="$(df -P "$APP" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
if [ -n "$use" ]; then if [ "$use" -ge 90 ]; then bad "disk ${use}% used"; why "a full disk stops logging, sessions and uploads"; elif [ "$use" -ge 80 ]; then warn "disk ${use}% used"; else ok "disk ${use}% used"; fi; fi
log="$APP/storage/logs/laravel.log"
if [ -f "$log" ]; then
  errs="$(tail -n 500 "$log" | grep -c '\.ERROR:' || true)"; size_mb=$(( $(wc -c < "$log") / 1048576 ))
  [ "$errs" -gt 0 ] && warn "$errs ERROR entries in the last 500 log lines (tail -n 50 $log)" || ok "no recent ERRORs in laravel.log"
  [ "$size_mb" -ge 500 ] && warn "laravel.log is ${size_mb}MB" && why "use LOG_CHANNEL=daily or logrotate"
fi
if [ -n "$SITE" ] && have curl; then
  code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve "$SITE:443:127.0.0.1" "https://$SITE/" 2>/dev/null || true)"; code="${code:-000}"
  case "$code" in 2??|3??) ok "local HTTPS $code" ;; 000) warn "local HTTPS request failed (nginx not on 443?)" ;; 5??) bad "local HTTPS $code"; why "check $log and the php-fpm log" ;; *) warn "local HTTPS $code" ;; esac
  if have openssl; then
    end="$(echo | openssl s_client -servername "$SITE" -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    if [ -n "$end" ]; then
      left=$(( ( $(date -d "$end" +%s 2>/dev/null || date -j -f '%b %d %T %Y %Z' "$end" +%s) - $(date +%s) ) / 86400 ))
      [ "$left" -lt 14 ] && warn "TLS certificate expires in $left days" || ok "TLS certificate: $left days left"
    fi
  fi
fi

# ---- fixes -----------------------------------------------------------------------------
uniq_fixes=(); for f in "${FIXES[@]+"${FIXES[@]}"}"; do [[ " ${uniq_fixes[*]+"${uniq_fixes[*]}"} " == *" $f "* ]] || uniq_fixes+=("$f"); done
if [ "$FIX" = 0 ]; then
  [ "${#uniq_fixes[@]}" -gt 0 ] && say "  fixable with --fix: ${uniq_fixes[*]}"
  summary
  [ "$JSON" = 1 ] && printf '{"ok":%d,"warn":%d,"fail":%d,"fixable":%d}\n' "$c_ok" "$c_warn" "$c_fail" "${#uniq_fixes[@]}"
  exit $(( c_fail > 0 ? 1 : 0 ))
fi
[ "${#uniq_fixes[@]}" -gt 0 ] || { summary; say "nothing to fix"; exit $(( c_fail > 0 ? 1 : 0 )); }
say ""; say "fix plan:"
for f in "${uniq_fixes[@]}"; do case "$f" in
  env_mode) say "  - chmod 600 $ENV_FILE" ;;
  debug_off) say "  - APP_DEBUG=false in $ENV_FILE (backup first)" ;;
  perms) say "  - mkdir -p + chown -R $OWNER + chmod -R u+rwX,g+rwX on storage and bootstrap/cache" ;;
  storage_link) say "  - php artisan storage:link" ;;
  config_cache) say "  - php artisan config:cache" ;;
esac; done
[ "$DRY" = 1 ] && { say "dry run - nothing changed"; exit 0; }
lock
if [ "$ENVN" = prd ]; then confirm "apply ${#uniq_fixes[@]} fix(es) on PRODUCTION" "${SITE:-$(basename "$SITE_PATH")}"
else confirm "apply ${#uniq_fixes[@]} fix(es)"; fi
audit confirmed "site=${SITE:-$SITE_PATH} env=$ENVN fixes=${uniq_fixes[*]}"
changed_env=0
for f in "${uniq_fixes[@]}"; do case "$f" in
  env_mode) chmod 600 "$ENV_FILE" ;;
  debug_off) backup "$ENV_FILE"; tmp="$(mktemp "$(dirname "$ENV_FILE")/.env.XXXXXX")"
             sed -E 's/^APP_DEBUG=.*/APP_DEBUG=false/' "$ENV_FILE" > "$tmp"; cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"; changed_env=1 ;;
  perms) for d in storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache; do mkdir -p "$APP/$d"; done
         [ -n "$R" ] || chown -R "$OWNER": "$APP/storage" "$APP/bootstrap/cache"
         chmod -R u+rwX,g+rwX "$APP/storage" "$APP/bootstrap/cache" ;;
  storage_link) (cd "$APP" && as_owner php artisan storage:link) ;;
  config_cache) changed_env=1 ;;
esac; ok "fixed: $f"; audit applied "site=${SITE:-$SITE_PATH} fix=$f"; done
if [ "$changed_env" = 1 ] && [ -f "$APP/artisan" ] && [ -f "$APP/bootstrap/cache/config.php" ]; then
  (cd "$APP" && as_owner php artisan config:cache >/dev/null) && ok "config cache rebuilt"
fi
summary; say "re-run without --fix to confirm"
audit succeeded "site=${SITE:-$SITE_PATH}"
