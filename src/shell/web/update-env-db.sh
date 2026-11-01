#!/usr/bin/env bash
# =============================================================================
#  update-env-db.sh - put DB_* settings into a Laravel .env, idempotently
# =============================================================================
#  Backs up the target .env (<file>.bak.<timestamp>), removes every existing
#  line for the keys being set, appends the new values, and prints the DB_*
#  lines with the password masked. Other lines (e.g. DB_SSLMODE) are untouched.
#
#  Values come from --from FILE (KEY=VALUE lines, e.g. the output of
#  `docker-db-server-manager.sh env` saved to a file), from --set KEY=VALUE
#  flags, or both (--set wins). Only DB_* keys are accepted. Values are never
#  hardcoded here.
#
#  USAGE
#    # on the web server
#    update-env-db.sh --env /home/ploi/example.com-shared/.env --from db.env
#
#    # from your workstation: copies this script + values over ssh and runs it
#    update-env-db.sh --remote web-alias --site example.com --from db.env
#
#  OPTIONS
#    --env FILE        target .env (default: /home/ploi/<site>-shared/.env)
#    --site DOMAIN     Ploi site domain, used to build the default --env path
#    --from FILE       KEY=VALUE file with DB_* values ("-" = stdin)
#    --set KEY=VALUE   set one key (repeatable)
#    --remote ALIAS    run on ALIAS over ssh instead of locally
#    --no-backup       skip the .bak copy (backups are chmod 600; the newest
#                      KEEP_BACKUPS, default 5, are kept)
#    --dry-run         print what would be written, change nothing
#    -h, --help
# =============================================================================
set -euo pipefail

ENV_FILE="" SITE="" FROM="" REMOTE="" BACKUP=1 DRY=0
SETS=()

die()   { printf '!! %s\n' "$*" >&2; exit 1; }
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env)       ENV_FILE="${2:?--env needs a path}"; shift 2 ;;
    --site)      SITE="${2:?--site needs a domain}"; shift 2 ;;
    --from)      FROM="${2:?--from needs a file}"; shift 2 ;;
    --set)       SETS+=("${2:?--set needs KEY=VALUE}"); shift 2 ;;
    --remote)    REMOTE="${2:?--remote needs an ssh alias}"; shift 2 ;;
    --no-backup) BACKUP=0; shift ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if [ -z "$ENV_FILE" ]; then
  [ -n "$SITE" ] || die "give --env FILE or --site DOMAIN"
  ENV_FILE="/home/ploi/$SITE-shared/.env"
fi

# ---- collect values --------------------------------------------------------
# Plain indexed arrays (no `declare -A`) so this also runs on macOS bash 3.2.
ORDER=(); VALS=()
add() { # add KEY=VALUE ; a later value for the same key wins
  local kv="$1" k v i
  kv="${kv%$'\r'}"
  [[ "$kv" =~ ^[[:space:]]*(#|$) ]] && return 0
  k="${kv%%=*}"; v="${kv#*=}"
  [[ "$k" =~ ^DB_[A-Z0-9_]+$ ]] || die "refusing non-DB_* key: $k"
  for i in "${!ORDER[@]}"; do
    if [ "${ORDER[$i]}" = "$k" ]; then VALS[i]="$v"; return 0; fi
  done
  ORDER+=("$k"); VALS+=("$v")
}
emit() { local i; for i in "${!ORDER[@]}"; do printf '%s=%s\n' "${ORDER[$i]}" "${VALS[$i]}"; done; }
if [ -n "$FROM" ]; then
  if [ "$FROM" = "-" ]; then src=/dev/stdin; else [ -r "$FROM" ] || die "cannot read $FROM"; src="$FROM"; fi
  while IFS= read -r line || [ -n "$line" ]; do add "$line"; done < "$src"
fi
for kv in "${SETS[@]+"${SETS[@]}"}"; do add "$kv"; done
[ "${#ORDER[@]}" -gt 0 ] || die "no DB_* values given (use --from or --set)"

# ---- remote mode: copy script + values over, run there, clean up ------------
if [ -n "$REMOTE" ]; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  (umask 077; emit > "$tmp")
  extra=""
  [ "$BACKUP" = 1 ] || extra+=" --no-backup"
  [ "$DRY" = 0 ] || extra+=" --dry-run"
  rdir="$(ssh "$REMOTE" 'umask 077; mktemp -d')" || die "ssh $REMOTE failed"
  scp -q "$0" "$REMOTE:$rdir/update-env-db.sh"
  scp -q "$tmp" "$REMOTE:$rdir/values.env"     # values never appear in argv
  # shellcheck disable=SC2029  # expanding locally is the point
  ssh "$REMOTE" "bash '$rdir/update-env-db.sh' --env '$ENV_FILE' --from '$rdir/values.env'$extra; rc=\$?; rm -rf '$rdir'; exit \$rc"
  exit $?
fi

# ---- local mode --------------------------------------------------------------
mask() { sed -E 's/^(DB_PASSWORD=).*/\1***/'; }

if [ "$DRY" = 1 ]; then
  echo "would write to $ENV_FILE:"
  emit | mask
  exit 0
fi

[ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist (deploy once in Ploi first, or create it)"
if [ "$BACKUP" = 1 ]; then
  bak="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
  (umask 077; cp "$ENV_FILE" "$bak"); chmod 600 "$bak"; echo "backup: $bak"
  # keep the newest KEEP_BACKUPS copies (they contain secrets)
  # shellcheck disable=SC2012  # timestamped names, no odd characters
  ls -1 "$ENV_FILE".bak.* 2>/dev/null | sort -r | tail -n +"$((${KEEP_BACKUPS:-5} + 1))" | while read -r old; do rm -f "$old"; echo "pruned: $old"; done
fi

pattern="^($(IFS='|'; echo "${ORDER[*]}"))="
tmpf="$(mktemp "$(dirname "$ENV_FILE")/.env.XXXXXX")"
trap 'rm -f "$tmpf"' EXIT
{ grep -vE "$pattern" "$ENV_FILE" || true
  emit
} > "$tmpf"
chmod --reference="$ENV_FILE" "$tmpf" 2>/dev/null || chmod 600 "$tmpf"
cat "$tmpf" > "$ENV_FILE"      # keep inode, owner and any symlink pointing at it
echo "updated $ENV_FILE:"
grep -E '^DB_' "$ENV_FILE" | mask
