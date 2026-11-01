#!/usr/bin/env bash
# examples/_shared/app-env.sh - write a non-Laravel app's settings on the web host from the DB manager's block.
#
#   app-env.sh --stack S --from FILE --out DIR [--set KEY=VALUE]... [--generate KEY]... [--pgpass FILE] [--dry-run]
#   app-env.sh --stack none --out DIR --generate KEY... [--set KEY=VALUE]...   secrets/settings only, no DB block
#   app-env.sh --self-test [--stack S]   offline check with a throwaway block (examples/run.sh runs this)
#   app-env.sh --list                     the stacks and what each one gets
#
# FILE is the DB_* block from the DB server: `sudo ./docker-db-server-manager.sh env-creds <env> [engine] --out F`,
# copied to the web host (then shred both copies). DIR is the app's shared folder (Ploi: /home/ploi/<site>-shared).
#   Postgres stacks: DIR/.env gets the libpq settings (PGHOST PGPORT PGDATABASE PGUSER PGSSLMODE PGSSLROOTCERT
#     PGPASSFILE) and the password goes only into a pgpass file (600), which every libpq-based driver reads
#     (psycopg, pg/node-postgres, pgx, the pg gem, pdo_pgsql). Symfony gets DATABASE_URL with a user, no password.
#   MySQL stacks (wordpress): DB_NAME DB_USER DB_PASSWORD DB_HOST (mysqli has no password file).
#   Each stack's own secret (Django, Rails, Symfony, WordPress salts, or --generate KEY) is generated here with
#   openssl rand the first time and never replaced. Other keys in an existing DIR/.env are kept (old file: .env.bak).
# Values are never printed. Exit: 0 ok, 1 error, 2 usage.
set -euo pipefail

CLEAN=""
cleanup() { local d; for d in $CLEAN; do rm -rf "$d"; done; }
trap cleanup EXIT
say() { printf '%s\n' "$*"; }
die() { printf 'app-env: %s\n' "$*" >&2; exit "${CODE:-1}"; }
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

STACKS="symfony django fastapi rails go nextjs nestjs wordpress none"
stack_kind() { case "$1" in wordpress) echo mysql ;; none) echo none ;; *) echo pg ;; esac; }
stack_secrets() { # keys generated once (openssl rand -hex 32 unless noted)
  case "$1" in
    symfony) echo APP_SECRET ;;
    django) echo DJANGO_SECRET_KEY ;;
    fastapi) echo SECRET_KEY ;;
    rails) echo SECRET_KEY_BASE ;;
    wordpress) echo AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT ;;
    *) echo "" ;;
  esac
}
stack_defaults() { # non-secret KEY=VALUE written only when the key is missing (yours win)
  case "$1" in
    symfony) echo APP_ENV=prod APP_DEBUG=0 ;;
    django) echo DJANGO_DEBUG=0 DJANGO_ALLOWED_HOSTS=example.com ;;
    fastapi) echo APP_ENV=production ;;
    rails) echo RAILS_ENV=production RAILS_LOG_LEVEL=info RAILS_MAX_THREADS=3 WEB_CONCURRENCY=2 ;;
    go) echo LISTEN_ADDR=127.0.0.1:8080 ;;
    nextjs) echo NODE_ENV=production HOSTNAME=127.0.0.1 PORT=3000 ;;
    nestjs) echo NODE_ENV=production HOST=127.0.0.1 PORT=3001 ;;
    wordpress) echo WP_ENV=production WP_HOME=https://example.com WP_SITEURL=https://example.com/wp DISABLE_WP_CRON=true ;;
  esac
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
gen() { openssl rand -hex "${1:-32}"; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

block_get() { # KEY FILE: value from a KEY=VALUE file (last one wins, surrounding quotes removed)
  AE_K="$1=" awk 'index($0, ENVIRON["AE_K"]) == 1 { v = substr($0, length(ENVIRON["AE_K"]) + 1) } END { print v }' "$2" |
    sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}
quote() { # a value for a dotenv file: bare when plain, single-quoted otherwise; never a quote or newline
  case "$1" in *"'"* | *$'\n'*) die "a value contains a quote or newline; refusing to write it" ;; esac
  if [[ "$1" =~ ^[A-Za-z0-9_./:@+=,%-]*$ ]]; then printf '%s' "$1"; else printf "'%s'" "$1"; fi
}
env_put() { # KEY VALUE FILE: replace or append (awk, so no sed escaping of the value)
  local tmp; tmp="$(mktemp "$3.XXXXXX")"
  # ENVIRON, not awk -v: -v would turn backslashes in the value into escapes
  AE_K="$1=" AE_LINE="$1=$(quote "$2")" awk 'index($0, ENVIRON["AE_K"]) == 1 { if (!done) print ENVIRON["AE_LINE"]; done = 1; next }
    { print } END { if (!done) print ENVIRON["AE_LINE"] }' "$3" > "$tmp"
  cat "$tmp" > "$3"; rm -f "$tmp"
}
pgpass_esc() { printf '%s' "$1" | sed 's/[\\:]/\\&/g'; }
pgpass_put() { # FILE host port db user password: one line per host:port:db:user, others kept
  local key line tmp
  key="$(pgpass_esc "$2"):$(pgpass_esc "$3"):$(pgpass_esc "$4"):$(pgpass_esc "$5"):"
  line="$key$(pgpass_esc "$6")"
  (umask 077; touch "$1"); chmod 600 "$1"
  tmp="$(mktemp "$1.XXXXXX")"
  AE_K="$key" AE_LINE="$line" awk 'index($0, ENVIRON["AE_K"]) == 1 { if (!done) print ENVIRON["AE_LINE"]; done = 1; next }
    { print } END { if (!done) print ENVIRON["AE_LINE"] }' "$1" > "$tmp"
  cat "$tmp" > "$1"; rm -f "$tmp"
}

run() { # stack from out pgpass dry sets secrets
  local stack="$1" from="$2" out="$3" pgpass="$4" dry="$5" sets="$6" extra="$7"
  local kind host port db user pw ssl ca env work k kv url
  in_list "$stack" "$STACKS" || CODE=2 die "unknown stack '$stack' (have: $STACKS)"
  [ -d "$out" ] || CODE=2 die "--out $out: no such directory"
  kind="$(stack_kind "$stack")"
  env="$out/.env"
  work="$(mktemp -d)"; CLEAN="$CLEAN $work"
  if [ -f "$env" ]; then cp "$env" "$work/env"; else : > "$work/env"; fi
  local report=()
  if [ "$kind" != none ]; then
    [ -f "$from" ] || CODE=2 die "--from $from: no such file"
    host="$(block_get DB_HOST "$from")"; port="$(block_get DB_PORT "$from")"
    db="$(block_get DB_DATABASE "$from")"; user="$(block_get DB_USERNAME "$from")"
    pw="$(block_get DB_PASSWORD "$from")"; ssl="$(block_get DB_SSLMODE "$from")"; ca="$(block_get DB_SSLROOTCERT "$from")"
    [ -n "$host" ] && [ -n "$port" ] && [ -n "$db" ] && [ -n "$user" ] && [ -n "$pw" ] ||
      die "$from needs DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME and DB_PASSWORD (env-creds <env> [engine] --out FILE)"
    case "$(block_get DB_CONNECTION "$from")" in
      pgsql) [ "$kind" = pg ] || die "$stack needs a MySQL/MariaDB block (env-creds <env> mysql), got pgsql" ;;
      mysql | mariadb) [ "$kind" = mysql ] || die "$stack needs a Postgres block, got $(block_get DB_CONNECTION "$from")" ;;
      *) die "$from: DB_CONNECTION must be pgsql, mysql or mariadb" ;;
    esac
    [ -n "$pgpass" ] || { if [ "$stack" = symfony ]; then pgpass="$HOME/.pgpass"; else pgpass="$out/.pgpass"; fi; }
    if [ "$kind" = pg ]; then
      env_put PGHOST "$host" "$work/env"; env_put PGPORT "$port" "$work/env"
      env_put PGDATABASE "$db" "$work/env"; env_put PGUSER "$user" "$work/env"
      report+=("PGHOST PGPORT PGDATABASE PGUSER (from the DB block)")
      [ -z "$ssl" ] || { env_put PGSSLMODE "$ssl" "$work/env"; report+=("PGSSLMODE"); }
      [ -z "$ca" ] || { env_put PGSSLROOTCERT "$ca" "$work/env"; report+=("PGSSLROOTCERT"); }
      if [ "$stack" = symfony ]; then
        # PHP-FPM does not export .env to libpq, so sslmode rides in the URL and the password in ~/.pgpass
        url="postgresql://$user@$host:$port/$db?serverVersion=18&charset=utf8"
        [ -z "$ssl" ] || url="$url&sslmode=$ssl"
        [ -z "$ca" ] || url="$url&sslrootcert=$ca"
        env_put DATABASE_URL "$url" "$work/env"; report+=("DATABASE_URL (user, no password)")
      else
        env_put PGPASSFILE "$pgpass" "$work/env"; report+=("PGPASSFILE")
      fi
    else
      env_put DB_NAME "$db" "$work/env"; env_put DB_USER "$user" "$work/env"
      env_put DB_PASSWORD "$pw" "$work/env"; env_put DB_HOST "$host:$port" "$work/env"
      report+=("DB_NAME DB_USER DB_PASSWORD DB_HOST (from the DB block)")
    fi
  fi # kind != none
  for kv in $(stack_defaults "$stack"); do
    k="${kv%%=*}"; [ -n "$(block_get "$k" "$work/env")" ] || { env_put "$k" "${kv#*=}" "$work/env"; report+=("$k (default)"); }
  done
  for kv in $sets; do env_put "${kv%%=*}" "${kv#*=}" "$work/env"; report+=("${kv%%=*} (--set)"); done
  for k in $(stack_secrets "$stack") $extra; do
    if [ -n "$(block_get "$k" "$work/env")" ]; then report+=("$k (kept)")
    else env_put "$k" "$(gen 32)" "$work/env"; report+=("$k (generated)"); fi
  done
  if [ "$dry" = 1 ]; then
    say "dry run: would write $env (600)$([ "$kind" = pg ] && printf ' and %s (600)' "$pgpass"); values not shown"
    printf '  %s\n' "${report[@]}"
    return 0
  fi
  if [ -f "$env" ]; then (umask 077; cp "$env" "$env.bak"); chmod 600 "$env.bak"; fi
  (umask 077; cat "$work/env" > "$work/env.new"); chmod 600 "$work/env.new"; mv "$work/env.new" "$env"
  [ "$kind" != pg ] || pgpass_put "$pgpass" "$host" "$port" "$db" "$user" "$pw"
  say "wrote $env (600)$([ "$kind" = pg ] && printf ' and %s (600)' "$pgpass")"
  printf '  %s\n' "${report[@]}"
}

self_test_none() { # --stack none: only --generate and --set, no DB block, no pgpass
  local t="$1" ok=0 first
  expect() { local what="$1"; shift; if "$@"; then ok=$((ok + 1)); else die "self-test none: $what"; fi; }
  mkdir -p "$t/shared" "$t/home"
  echo "APP_NAME=Shop" > "$t/shared/.env"
  HOME="$t/home" run none "" "$t/shared" "" 0 "REVERB_PORT=443" " REVERB_APP_KEY REVERB_APP_SECRET" > /dev/null
  first="$(block_get REVERB_APP_SECRET "$t/shared/.env")"
  expect "REVERB_APP_SECRET was not generated" test "${#first}" -eq 64
  expect "REVERB_APP_KEY was not generated" test "$(block_get REVERB_APP_KEY "$t/shared/.env" | wc -c)" -gt 32
  expect "the --set value is missing" test "$(block_get REVERB_PORT "$t/shared/.env")" = 443
  expect "a key of yours was dropped" test "$(block_get APP_NAME "$t/shared/.env")" = Shop
  expect "a pgpass was written" test ! -e "$t/shared/.pgpass"
  expect "a DB key was written" test "$(grep -c '^PG\|^DB_' "$t/shared/.env")" = 0
  HOME="$t/home" run none "" "$t/shared" "" 0 "" " REVERB_APP_KEY REVERB_APP_SECRET" > /dev/null
  expect "a generated secret was replaced on the second run" test "$(block_get REVERB_APP_SECRET "$t/shared/.env")" = "$first"
  expect ".env is not 600" test "$(file_mode "$t/shared/.env")" = 600
  say "app-env self-test none: ok ($ok checks)"
}

self_test() { # stack: a throwaway block with a generated password, checked end to end
  local stack="$1" t kind pw pgp ok=0 first again k
  t="$(mktemp -d)"; CLEAN="$CLEAN $t"
  kind="$(stack_kind "$stack")"
  [ "$kind" != none ] || { self_test_none "$t"; return; }
  pw="$(gen 12):x\\y"   # generated, plus the two characters pgpass must escape
  mkdir -p "$t/home" "$t/shared"
  if [ "$kind" = pg ]; then
    printf 'DB_CONNECTION=pgsql\nDB_HOST=10.0.0.5\nDB_PORT=6432\nDB_DATABASE=app_dev\nDB_USERNAME=app_dev_app\nDB_PASSWORD=%s\nDB_SSLMODE=require\n' "$pw" > "$t/db.env"
  else
    printf 'DB_CONNECTION=mysql\nDB_HOST=10.0.0.5\nDB_PORT=3306\nDB_DATABASE=app_dev\nDB_USERNAME=app_dev_app\nDB_PASSWORD=%s\n' "$pw" > "$t/db.env"
  fi
  expect() { local what="$1"; shift; if "$@"; then ok=$((ok + 1)); else die "self-test $stack: $what"; fi; }
  secrets() { for k in $(stack_secrets "$stack"); do block_get "$k" "$t/shared/.env"; done; }
  HOME="$t/home" run "$stack" "$t/db.env" "$t/shared" "" 1 "" "" > /dev/null
  expect "the dry run wrote a file" test ! -e "$t/shared/.env"
  HOME="$t/home" run "$stack" "$t/db.env" "$t/shared" "" 0 "EXTRA_FLAG=on" "" > /dev/null
  expect ".env is not 600" test "$(file_mode "$t/shared/.env")" = 600
  expect "the --set value is missing" test "$(block_get EXTRA_FLAG "$t/shared/.env")" = on
  if [ "$kind" = pg ]; then
    pgp="$t/shared/.pgpass"; [ "$stack" != symfony ] || pgp="$t/home/.pgpass"
    expect "the password leaked into .env" test "$(grep -cF -- "${pw%%:*}" "$t/shared/.env")" = 0
    expect "pgpass is not 600" test "$(file_mode "$pgp")" = 600
    expect "the pgpass line is wrong" test "$(cat "$pgp")" = "10.0.0.5:6432:app_dev:app_dev_app:$(pgpass_esc "$pw")"
    expect "PGHOST is wrong" test "$(block_get PGHOST "$t/shared/.env")" = 10.0.0.5
    if [ "$stack" = symfony ]; then
      expect "DATABASE_URL carries a password" test "$(block_get DATABASE_URL "$t/shared/.env" | grep -c '//[^@/]*:[^@/]*@')" = 0
      expect "DATABASE_URL lacks sslmode" test "$(block_get DATABASE_URL "$t/shared/.env" | grep -c 'sslmode=require')" = 1
    else
      expect "PGPASSFILE is wrong" test "$(block_get PGPASSFILE "$t/shared/.env")" = "$pgp"
      # shellcheck disable=SC2016 # the inner sh expands them, after with-env.sh exported them
      expect "with-env.sh did not export the settings" \
        test "$("$(dirname "$0")/with-env.sh" "$t/shared/.env" sh -c 'printf "%s %s" "$PGHOST" "$PGSSLMODE"')" = "10.0.0.5 require"
    fi
  else
    expect "DB_PASSWORD is wrong" test "$(block_get DB_PASSWORD "$t/shared/.env")" = "$pw"
    expect "DB_HOST is wrong" test "$(block_get DB_HOST "$t/shared/.env")" = 10.0.0.5:3306
  fi
  first="$(secrets)"
  for k in $(stack_secrets "$stack"); do expect "$k was not generated" test "$(block_get "$k" "$t/shared/.env" | wc -c)" -gt 32; done
  echo "KEEP_ME=1" >> "$t/shared/.env"
  HOME="$t/home" run "$stack" "$t/db.env" "$t/shared" "" 0 "" "" > /dev/null
  again="$(secrets)"
  expect "a generated secret was replaced on the second run" test "$first" = "$again"
  expect "a key of yours was dropped" test "$(block_get KEEP_ME "$t/shared/.env")" = 1
  expect "no 600 .env.bak was kept" test "$(file_mode "$t/shared/.env.bak")" = 600
  [ "$kind" != pg ] || expect "pgpass grew a duplicate line" test "$(wc -l < "$pgp" | tr -d ' ')" = 1
  say "app-env self-test $stack: ok ($ok checks)"
}

stack="" from="" out="" pgpass="" dry=0 sets="" extra="" mode=run
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) stack="${2:?--stack needs a value}"; shift 2 ;;
    --from) from="${2:?--from needs a file}"; shift 2 ;;
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    --pgpass) pgpass="${2:?--pgpass needs a file}"; shift 2 ;;
    --set) [[ "${2:-}" =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]*$ ]] || CODE=2 die "--set KEY=VALUE (no spaces)"; sets="$sets $2"; shift 2 ;;
    --generate) [[ "${2:-}" =~ ^[A-Z][A-Z0-9_]*$ ]] || CODE=2 die "--generate KEY"; extra="$extra $2"; shift 2 ;;
    --dry-run | -n) dry=1; shift ;;
    --self-test) mode=self-test; shift ;;
    --list) mode=list; shift ;;
    -h | --help) usage; exit 0 ;;
    *) CODE=2 die "unknown argument $1 (see --help)" ;;
  esac
done
command -v openssl > /dev/null 2>&1 || die "openssl is needed to generate secrets"
case "$mode" in
  list) for s in $STACKS; do printf '%-10s %-6s secrets: %s\n' "$s" "$(stack_kind "$s")" "$(stack_secrets "$s" | sed 's/^$/-/')"; done ;;
  self-test) if [ -n "$stack" ]; then self_test "$stack"; else for s in $STACKS; do self_test "$s"; done; fi ;;
  run)
    if [ -z "$stack" ] || [ -z "$out" ]; then usage >&2; exit 2; fi
    if [ "$stack" = none ]; then [ -n "$sets$extra" ] || CODE=2 die "--stack none needs --generate KEY or --set KEY=VALUE"
    else [ -n "$from" ] || CODE=2 die "--stack $stack needs --from FILE (the DB block)"; fi
    run "$stack" "$from" "$out" "$pgpass" "$dry" "$sets" "$extra" ;;
esac
