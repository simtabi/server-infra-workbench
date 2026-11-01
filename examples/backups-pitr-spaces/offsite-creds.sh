#!/usr/bin/env bash
# examples/backups-pitr-spaces/offsite-creds.sh - write the DB server's off-site credentials file, once.
#
#   sudo bash offsite-creds.sh                   asks for the Spaces key pair (hidden), generates the rest
#   sudo bash offsite-creds.sh --dir DIR         default /etc/server-infra-workbench
#   bash offsite-creds.sh --self-test            offline, throwaway directory
#
# Writes DIR/offsite.env (600): OFFSITE_ACCESS_KEY, OFFSITE_SECRET_KEY (typed, never in argv or history) and
# PITR_CIPHER_PASS (generated), and DIR/backup.key (600, generated) for the encrypted dump copies.
# Why generate the cipher here: the manager would otherwise create PITR_CIPHER_PASS in the stack's .env,
# which is lost with the droplet - exactly when the encrypted pgBackRest repo is needed. Here it sits next to
# the keys, in the one folder you escrow. Existing values are never replaced (that would orphan every backup
# already encrypted with them). Values are never printed.
set -euo pipefail
dir=/etc/server-infra-workbench
die() { printf 'offsite-creds: %s\n' "$1" >&2; exit "${2:-1}"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
has() { grep -qE "^$1=.+" "$2" 2>/dev/null; }

write_creds() { # DIR; reads the key pair from stdin when it is needed
  local d="$1" f="$1/offsite.env" k s tmp
  (umask 077; mkdir -p "$d"); chmod 700 "$d"
  tmp="$(mktemp "$d/.offsite.XXXXXX")"; chmod 600 "$tmp"
  [ ! -f "$f" ] || cat "$f" > "$tmp"
  if ! has OFFSITE_ACCESS_KEY "$tmp"; then
    [ -t 0 ] && printf 'Spaces access key (scoped to the backup bucket): ' >&2
    IFS= read -r k || true; [ -n "$k" ] || { rm -f "$tmp"; die "no access key given"; }
    printf 'OFFSITE_ACCESS_KEY=%s\n' "$k" >> "$tmp"
  fi
  if ! has OFFSITE_SECRET_KEY "$tmp"; then
    [ -t 0 ] && printf 'Spaces secret (hidden): ' >&2
    IFS= read -rs s || true; [ -t 0 ] && echo >&2
    [ -n "$s" ] || { rm -f "$tmp"; die "no secret given"; }
    printf 'OFFSITE_SECRET_KEY=%s\n' "$s" >> "$tmp"
  fi
  has PITR_CIPHER_PASS "$tmp" || printf 'PITR_CIPHER_PASS=%s\n' "$(openssl rand -hex 32)" >> "$tmp"
  mv -f "$tmp" "$f"
  if [ ! -s "$d/backup.key" ]; then (umask 077; openssl rand -base64 48 > "$d/backup.key"); fi
  chmod 600 "$f" "$d/backup.key"
  echo "wrote $f and $d/backup.key (600). Escrow BOTH off this server now (password manager):"
  echo "  without them, the off-site dumps and the pgBackRest repo cannot be decrypted after a droplet loss."
}

self_test() {
  local t ok=0 first
  TESTDIR="$(mktemp -d)"; t="$TESTDIR"; trap 'rm -rf "$TESTDIR"' EXIT
  expect() { local what="$1"; shift; if "$@"; then ok=$((ok + 1)); else die "self-test: $what"; fi; }
  printf '%s\n%s\n' "test-access-$(openssl rand -hex 4)" "$(openssl rand -hex 20)" | write_creds "$t/etc" > /dev/null
  expect "offsite.env not 600" test "$(mode_of "$t/etc/offsite.env")" = 600
  expect "backup.key not 600" test "$(mode_of "$t/etc/backup.key")" = 600
  expect "dir not 700" test "$(mode_of "$t/etc")" = 700
  expect "access key missing" has OFFSITE_ACCESS_KEY "$t/etc/offsite.env"
  expect "secret missing" has OFFSITE_SECRET_KEY "$t/etc/offsite.env"
  expect "cipher pass too short" test "$(sed -n 's/^PITR_CIPHER_PASS=//p' "$t/etc/offsite.env" | tr -d '\n' | wc -c)" -eq 64
  first="$(cat "$t/etc/offsite.env" "$t/etc/backup.key")"
  write_creds "$t/etc" < /dev/null > /dev/null
  expect "a second run changed a value" test "$(cat "$t/etc/offsite.env" "$t/etc/backup.key")" = "$first"
  expect "a temp file was left behind" test "$(find "$t/etc" -name '.offsite.*' | wc -l | tr -d ' ')" = 0
  rm -f "$t/etc/offsite.env"
  if printf '' | write_creds "$t/etc" > /dev/null 2>&1; then die "self-test: an empty key was accepted"; else ok=$((ok + 1)); fi
  echo "offsite-creds self-test: ok ($ok checks)"
}

case "${1:-}" in
  --self-test) self_test; exit 0 ;;
  --dir) dir="${2:?--dir needs a path}" ;;
  "") ;;
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown argument: $1" 2 ;;
esac
[ "$(id -u)" -eq 0 ] || [ "$dir" != /etc/server-infra-workbench ] || die "run as root (sudo)"
write_creds "$dir"
