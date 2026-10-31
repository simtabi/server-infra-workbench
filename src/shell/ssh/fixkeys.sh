#!/usr/bin/env bash
# =============================================================================
#  fixkeys.sh - repair authorized_keys from a provider web console (lockout recovery)
# =============================================================================
#  Self-contained on purpose: paste it into DigitalOcean's Recovery/Droplet
#  Console, GCP serial console, etc. No ssh, no Python, no other files needed.
#  Prompts read from the terminal (/dev/tty), so pasting the script does not
#  feed its own text to the menu.
#
#  USAGE
#    bash fixkeys.sh                         menu (list, add, remove, perms, diagnose, restore)
#    bash fixkeys.sh list   [--user U]
#    bash fixkeys.sh add    --user U 'ssh-ed25519 AAAA... me@laptop'   (or --key-file F)
#    bash fixkeys.sh remove --user U 2       (number from list, or SHA256:fingerprint)
#    bash fixkeys.sh perms  --user U         fix .ssh 700 / file 600 / owner / home not writable
#    bash fixkeys.sh diagnose --user U       why key login fails (effective sshd -T settings)
#    bash fixkeys.sh restore --user U [BACKUP]   put a .bak.<ts> copy back (current one backed up)
#
#  OPTIONS
#    --user U       whose keys (default: you; root sees every user with ~/.ssh)
#    --file PATH    edit this file instead (e.g. a custom AuthorizedKeysFile)
#    --root DIR     the server's disk is mounted at DIR (DO recovery ISO: /mnt);
#                   users, homes and owners are read from DIR/etc/passwd
#    --key-file F   read the public key to add from F
#    --yes, -y      no y/N prompts (removing the LAST key still needs typed EMPTY)
#    -h, --help
#  ENV  FIXKEYS_TTY  where prompts are read from (default /dev/tty; tests use a file)
#
#  Every change: backup <file>.bak.<ts> (600), atomic write, owner + modes
#  restored, a line in <root>/var/log/vps-server-workbench/audit.log
#  (fingerprints only). Keys are validated with ssh-keygen before they go in.
# =============================================================================
# shellcheck disable=SC2015  # 'test && say || say': say cannot fail
set -u
VERSION=2.0.0
TTY="${FIXKEYS_TTY:-}"; if [ -z "$TTY" ]; then if [ -r /dev/tty ] && : 2>/dev/null </dev/tty; then TTY=/dev/tty; else TTY=/dev/stdin; fi; fi
exec 3<"$TTY" || exec 3</dev/null   # opened once: answers are read in order, even from a file
# messages: fd 4 = the terminal, or stderr (dup'd, so a redirected log is appended to, not truncated)
if [ -z "${FIXKEYS_TTY:-}" ] && { : >/dev/tty; } 2>/dev/null; then exec 4>/dev/tty; else exec 4>&2; fi

say()  { printf '%s\n' "$*" >&4; }
die()  { printf 'fixkeys: %s\n' "$*" >&2; exit "${CODE:-1}"; }
ask()  { local p="$1" d="${2:-}" r; if [ -n "$d" ]; then printf '%s [%s]: ' "$p" "$d" >&4; else printf '%s: ' "$p" >&4; fi
         IFS= read -r r <&3 || r=""; printf '%s' "${r:-$d}"; }
confirm() { [ "$YES" = 1 ] && return 0; local r; printf '%s (y/N): ' "$1" >&4; IFS= read -r r <&3 || r=""
            case "$r" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }
typed() { local r; printf 'Type %s to %s: ' "$1" "$2" >&4; IFS= read -r r <&3 || r=""; [ "$r" = "$1" ]; }
have() { command -v "$1" >/dev/null 2>&1; }
own_ok() { [ -z "$UID_GID" ] || [ "$1" = "$UID_GID" ]; }
gw() { [ -n "$1" ] && [ $(( 8#$1 & 8#022 )) -ne 0 ]; }   # group/other writable
fmode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
fowner() { stat -c '%u:%g' "$1" 2>/dev/null || stat -f '%u:%g' "$1" 2>/dev/null; }
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); print}' "$0"; }

CMD="" ARG="" AK_USER="" FILE="" ROOT="" KEYFILE="" YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    list|add|remove|perms|diagnose|restore|menu) CMD="$1"; shift ;;
    --user) AK_USER="${2:?--user needs a name}"; shift 2 ;;
    --file) FILE="${2:?--file needs a path}"; shift 2 ;;
    --root) ROOT="${2:?--root needs a dir}"; ROOT="${ROOT%/}"; shift 2 ;;
    --key-file) KEYFILE="${2:?}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "fixkeys $VERSION"; exit 0 ;;
    -----*) ARG="$1"; shift ;;   # a pasted PEM block: do_add explains why it is refused
    -*) CODE=2 die "unknown option: $1 (see --help)" ;;
    *) [ -z "$ARG" ] || CODE=2 die "unexpected argument: $1"; ARG="$1"; shift ;;
  esac
done
[ -z "$ROOT" ] || [ -d "$ROOT/etc" ] || CODE=2 die "--root $ROOT has no etc/ - is the disk mounted there?"
[[ -z "$AK_USER" || "$AK_USER" =~ ^[a-z_][a-z0-9_.-]*\$?$ ]] || CODE=2 die "bad --user"

# ---- who and which file -------------------------------------------------------------------
pw() { awk -F: -v u="$1" -v f="$2" '$1 == u { print $f; exit }' "$ROOT/etc/passwd" 2>/dev/null; }   # pw user field
audit() { local d="$ROOT/var/log/vps-server-workbench"; { mkdir -p "$d" && chmod 700 "$d"; } 2>/dev/null || return 0
  printf '%s tool=fixkeys by=%s host=%s outcome=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-$(id -un)}" \
    "$(hostname 2>/dev/null || echo '?')" "$1" "${*:2}" >> "$d/audit.log" 2>/dev/null || true
  have logger && [ -z "$ROOT" ] && logger -t fixkeys "outcome=$1 ${*:2}" 2>/dev/null || true; }

ak_file_setting() { # effective AuthorizedKeysFile for the user (first entry), "" when it's the default
  [ -z "$ROOT" ] && have sshd || return 0
  local v; v="$(sshd -T -C "user=$AK_USER,host=localhost,addr=127.0.0.1" 2>/dev/null | awk '$1 == "authorizedkeysfile" { print $2; exit }')"
  case "$v" in ""|.ssh/authorized_keys|"%h/.ssh/authorized_keys") return 0 ;; esac
  v="${v//%%/@PCT@}"; v="${v//%h/$AK_HOME}"; v="${v//%u/$AK_USER}"; v="${v//@PCT@/%}"
  case "$v" in /*) ;; *) v="$AK_HOME/$v" ;; esac; printf '%s' "$v"; }

pick_user() {
  if [ -z "$AK_USER" ]; then
    local c=() d; [ -d "$ROOT/root/.ssh" ] && c+=(root)
    for d in "$ROOT"/home/*; do [ -d "$d/.ssh" ] && c+=("$(basename "$d")"); done
    [ "${#c[@]}" -gt 0 ] && say "users with ~/.ssh: ${c[*]}"
    if [ "$CMD" = menu ]; then AK_USER="$(ask "Whose authorized_keys" "$(id -un)")"; else AK_USER="$(id -un)"; fi
    [[ "$AK_USER" =~ ^[a-z_][a-z0-9_.-]*\$?$ ]] || die "bad user name"
  fi
  AK_HOME="$(pw "$AK_USER" 6)"
  if [ -z "$AK_HOME" ]; then [ "$AK_USER" = root ] && AK_HOME=/root || AK_HOME="/home/$AK_USER"
    say "note: $AK_USER is not in $ROOT/etc/passwd - using $AK_HOME"; fi
  UID_GID=""; local u g; u="$(pw "$AK_USER" 3)"; g="$(pw "$AK_USER" 4)"; [ -n "$u" ] && UID_GID="$u:$g"
  if [ -n "$FILE" ]; then AK_FILE="$FILE"
  else
    local custom; custom="$(ak_file_setting)"
    if [ -n "$custom" ]; then AK_FILE="$custom"; say "sshd reads keys from AuthorizedKeysFile $custom for $AK_USER"
    else AK_FILE="$AK_HOME/.ssh/authorized_keys"; fi
    AK_FILE="$ROOT$AK_FILE"
  fi
  AK_DIR="$(dirname "$AK_FILE")"; AK_HOME="$ROOT$AK_HOME"
  say "managing: $AK_FILE"
}

# ---- key helpers --------------------------------------------------------------------------
KTYPES='ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com'
key_of() { awk -v t="^($KTYPES)\$" '{ for (i = 1; i <= NF; i++) if ($i ~ t) { if (i < NF) print $i " " $(i+1); exit } }' <<<"$1"; }  # "type body", options skipped
label_of() { awk -v t="^($KTYPES)\$" '{ for (i = 1; i <= NF; i++) if ($i ~ t) { s = ""; for (j = i + 2; j <= NF; j++) s = s (j > i + 2 ? " " : "") $j; print (s == "" ? $i : s); exit } }' <<<"$1"; }
fp_of() { have ssh-keygen || { printf '(no ssh-keygen)'; return; }
  local o; o="$(ssh-keygen -l -f /dev/stdin <<<"$1" 2>/dev/null | awk '{print $2}')"; printf '%s' "${o:-(unreadable)}"; }
valid_key() { # ssh-keygen must parse it; without ssh-keygen, the type + base64 shape must hold
  [ -n "$(key_of "$1")" ] || return 1
  if have ssh-keygen; then ssh-keygen -l -f /dev/stdin <<<"$1" >/dev/null 2>&1; return; fi
  awk '{ exit !($2 ~ /^[A-Za-z0-9+\/]+=*$/ && length($2) >= 60) }' <<<"$(key_of "$1")"; }
key_lines() { [ -f "$AK_FILE" ] || return 0; while IFS= read -r l || [ -n "$l" ]; do case "$l" in ''|\#*) continue ;; esac; [ -n "$(key_of "$l")" ] && printf '%s\n' "$l"; done <"$AK_FILE"; }
count_keys() { key_lines | grep -c . || true; }
has_key() { local want; want="$(key_of "$1")"; key_lines | while IFS= read -r l; do [ "$(key_of "$l")" = "$want" ] && { echo y; break; }; done | grep y >/dev/null; }

set_owner() { [ -n "$UID_GID" ] && [ "$(id -u)" -eq 0 ] && chown "$UID_GID" "$@" 2>/dev/null; have restorecon && [ -z "$ROOT" ] && restorecon -F "$@" 2>/dev/null; return 0; }
ensure_file() { # ~/.ssh: 700 + owner; a shared dir from AuthorizedKeysFile (/etc/ssh/keys) is only created, never re-owned
  if [ "$AK_DIR" = "$AK_HOME/.ssh" ]; then mkdir -p "$AK_DIR" && chmod 700 "$AK_DIR" && set_owner "$AK_DIR"
  else mkdir -p "$AK_DIR"; fi
  [ -f "$AK_FILE" ] || : > "$AK_FILE"; chmod 600 "$AK_FILE"; set_owner "$AK_FILE"; }
backup_file() { [ -s "$AK_FILE" ] || return 0; local b; b="$AK_FILE.bak.$(date +%Y%m%d-%H%M%S)"; [ -e "$b" ] && b="$b.$$"
  cp -p "$AK_FILE" "$b" && chmod 600 "$b" && say "  backup: $b"; }
write_atomic() { local t; t="$(mktemp "$AK_DIR/.authorized_keys.XXXXXX")" || die "cannot write in $AK_DIR"; cat > "$t"; chmod 600 "$t"
  set_owner "$t"; mv "$t" "$AK_FILE"; }

# ---- actions ------------------------------------------------------------------------------
do_list() { local n=0 l; [ -s "$AK_FILE" ] || { say "  no keys in $AK_FILE"; return 1; }
  while IFS= read -r l; do n=$((n + 1)); say "  $n. $(label_of "$l")  $(awk '{print $1}' <<<"$(key_of "$l")")  $(fp_of "$l")"; done < <(key_lines)
  [ "$n" -gt 0 ] || { say "  no keys"; return 1; }; }

do_add() { local k="${1:-}"
  [ -n "$KEYFILE" ] && { [ -r "$KEYFILE" ] || die "cannot read $KEYFILE"; k="$(grep -vE '^[[:space:]]*(#|$)' "$KEYFILE" | head -1)"; }
  if [ -z "$k" ]; then say "Paste the PUBLIC key line (ssh-ed25519 ..., ssh-rsa ..., ecdsa-...):"; IFS= read -r k <&3 || k=""; fi
  k="$(printf '%s' "$k" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$k" ] || { say "  nothing pasted"; return 1; }
  case "$k" in *PRIVATE\ KEY*) say "  that is a PRIVATE key - never paste it anywhere. Use the .pub file."; return 1 ;; esac
  valid_key "$k" || { say "  not a valid public key (ssh-keygen could not read it)"; return 1; }
  say "  key: $(label_of "$k")  $(fp_of "$k")"
  if has_key "$k"; then say "  already present - nothing to do"; return 0; fi
  confirm "  add this key for $AK_USER?" || { say "  cancelled"; return 3; }
  ensure_file; backup_file
  { cat "$AK_FILE"; [ -s "$AK_FILE" ] && [ -n "$(tail -c1 "$AK_FILE")" ] && echo; printf '%s\n' "$k"; } | write_atomic
  audit added "user=$AK_USER file=$AK_FILE fp=$(fp_of "$k")"; say "  added. Test a NEW ssh login before closing this console."; }

do_remove() { local sel="${1:-}" target="" n=0 l
  do_list || return 1
  [ -n "$sel" ] || sel="$(ask "Number (or SHA256:fingerprint) to REMOVE, 0 cancels" 0)"
  case "$sel" in 0|"") say "  cancelled"; return 3 ;; esac
  while IFS= read -r l; do n=$((n + 1)); if [ "$sel" = "$n" ] || [ "$sel" = "$(fp_of "$l")" ]; then target="$l"; break; fi; done < <(key_lines)
  [ -n "$target" ] || { say "  no key matches $sel"; return 1; }
  local want left; want="$(key_of "$target")"
  left="$(while IFS= read -r l || [ -n "$l" ]; do [ -n "$(key_of "$l")" ] && [ "$(key_of "$l")" = "$want" ] && continue; printf '%s\n' "$l"; done <"$AK_FILE")"
  local remain; remain="$(printf '%s\n' "$left" | while IFS= read -r l; do [ -n "$(key_of "$l")" ] && echo k; done | grep -c k || true)"
  say "  remove: $(label_of "$target")  $(fp_of "$target")  ($remain key(s) would remain)"
  if [ "$remain" -eq 0 ]; then say "  WARNING: this is the LAST key - nobody will be able to log in with a key as $AK_USER"
    typed EMPTY "leave $AK_FILE with no keys" || { say "  aborted (good call)"; return 3; }
  else confirm "  remove it?" || { say "  cancelled"; return 3; }; fi
  backup_file; printf '%s\n' "$left" | sed '/^$/d' | write_atomic
  audit removed "user=$AK_USER file=$AK_FILE fp=$(fp_of "$target") remaining=$remain"; say "  removed; $remain key(s) remain"; }

do_perms() { local hm; ensure_file
  hm="$(fmode "$AK_HOME")"
  if gw "$hm"; then chmod go-w "$AK_HOME"; say "  home $AK_HOME was $hm - removed group/other write (sshd StrictModes refuses keys otherwise)"; fi
  audit perms "user=$AK_USER file=$AK_FILE"; say "  .ssh 700, authorized_keys 600${UID_GID:+, owner $UID_GID}"; }

do_restore() { local b="${1:-}" list=() f i=0
  for f in "$AK_FILE".bak.*; do [ -f "$f" ] && list+=("$f"); done
  [ "${#list[@]}" -gt 0 ] || { say "  no backups next to $AK_FILE"; return 1; }
  if [ -z "$b" ]; then
    for f in "${list[@]}"; do i=$((i + 1)); say "  $i. $(basename "$f")  ($(grep -cE "($KTYPES) " "$f" || true) key(s))"; done
    b="$(ask "Backup number to restore (0 cancels)" "${#list[@]}")"
    case "$b" in 0|"") say "  cancelled"; return 3 ;; *[!0-9]*) say "  not a number"; return 1 ;; esac
    [ "$b" -le "${#list[@]}" ] || { say "  no backup $b"; return 1; }; b="${list[$((b - 1))]}"
  fi
  case "$b" in /*) ;; *) b="$AK_DIR/$(basename "$b")" ;; esac
  case "$b" in "$AK_FILE".bak.*) ;; *) die "only $AK_FILE.bak.* files can be restored" ;; esac
  [ -f "$b" ] || die "no such backup: $b"
  confirm "  restore $(basename "$b") over the current file (which is backed up first)?" || { say "  cancelled"; return 3; }
  ensure_file; backup_file; write_atomic < "$b"; audit restored "user=$AK_USER file=$AK_FILE from=$(basename "$b")"; say "  restored"; }

do_diagnose() { local m o hm
  say ""; say "diagnosis for $AK_USER (home ${AK_HOME#"$ROOT"}):"
  if [ -d "$AK_DIR" ]; then m="$(fmode "$AK_DIR")"; o="$(fowner "$AK_DIR")"
    [ "$m" = 700 ] && own_ok "$o" && say "  ok    ~/.ssh $m $o" || say "  FIX   ~/.ssh is $m $o (want 700 ${UID_GID:-owner}) -> perms"
  else say "  FIX   ~/.ssh is missing -> perms or add"; fi
  if [ -f "$AK_FILE" ]; then m="$(fmode "$AK_FILE")"; o="$(fowner "$AK_FILE")"
    ! gw "$m" && own_ok "$o" && say "  ok    authorized_keys $m $o" || say "  FIX   authorized_keys is $m $o (want 600 ${UID_GID:-owner}) -> perms"
    say "  info  $(count_keys) key(s); $(grep -cvE "^[[:space:]]*(#|$)|($KTYPES) " "$AK_FILE" || true) unreadable line(s)"
    grep -q $'\r' "$AK_FILE" && say "  FIX   Windows line endings (CR) in the file - sshd ignores those lines; re-add the keys"
  else say "  FIX   $AK_FILE is missing"; fi
  hm="$(fmode "$AK_HOME")"; [ -n "$hm" ] && { ! gw "$hm" && say "  ok    home $hm" || say "  FIX   home is $hm: group/other writable -> sshd refuses keys -> perms"; }
  local sh; sh="$(pw "$AK_USER" 7)"; case "$sh" in */nologin|*/false) say "  FIX   login shell is $sh - no interactive login (usermod -s /bin/bash $AK_USER)" ;; esac
  if [ -z "$ROOT" ] && have passwd; then case "$(passwd -S "$AK_USER" 2>/dev/null | awk '{print $2}')" in
    L|LK) say "  warn  password is LOCKED (passwd -S): fine for key login with UsePAM yes (Ubuntu default); with UsePAM no, sshd refuses the account - 'usermod -p \"*\" $AK_USER' unlocks key login without a password" ;; esac; fi
  local sd="$ROOT/etc/ssh/sshd_config"
  if [ -z "$ROOT" ] && have sshd; then
    local t; t="$(sshd -T -C "user=$AK_USER,host=localhost,addr=127.0.0.1" 2>&1)" || { say "  FIX   sshd -T failed: $(head -1 <<<"$t") - fix the config before reloading ssh"; t=""; }
    if [ -n "$t" ]; then
      for o in pubkeyauthentication passwordauthentication permitrootlogin authorizedkeysfile strictmodes allowusers allowgroups denyusers denygroups pubkeyacceptedalgorithms; do
        l="$(awk -v k="$o" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$t")"; [ -n "$l" ] && say "  sshd  $o $l"; done
      grep -q '^pubkeyauthentication no' <<<"$t" && say "  FIX   PubkeyAuthentication is off"
      [ "$AK_USER" = root ] && grep -q '^permitrootlogin no' <<<"$t" && say "  FIX   PermitRootLogin no - root cannot log in at all; use a sudo user"
      grep -qE '^allowusers ' <<<"$t" && ! grep -qE "^allowusers .*\b$AK_USER(@|\b)" <<<"$t" && say "  FIX   AllowUsers does not include $AK_USER"
      grep -qE '^pubkeyacceptedalgorithms ' <<<"$t" && key_lines | grep '^ssh-rsa\|[[:space:]]ssh-rsa ' >/dev/null && ! grep -q 'rsa-sha2' <<<"$t" && say "  warn  RSA keys need rsa-sha2-* in PubkeyAcceptedAlgorithms"
    fi
  elif [ -r "$sd" ]; then
    say "  info  (no sshd -T: reading $sd and sshd_config.d/*.conf; first match wins)"
    for o in PubkeyAuthentication PasswordAuthentication PermitRootLogin AuthorizedKeysFile AllowUsers; do
      l="$(cat "$ROOT"/etc/ssh/sshd_config.d/*.conf "$sd" 2>/dev/null | grep -iE "^[[:space:]]*${o}[[:space:]]" | head -1)"; [ -n "$l" ] && say "  sshd  $l"; done
  fi
  [ -z "$ROOT" ] && have journalctl && { l="$(journalctl -u ssh -u sshd --since -1h --no-pager -q 2>/dev/null | grep -iE "Authentication refused|bad ownership|User $AK_USER .*not allowed" | tail -2)"; [ -n "$l" ] && say "  log   $l"; }
  say ""; say "after a fix: from your computer, ssh -v $AK_USER@<ip> and look for 'Offering public key' / 'Server accepts key'"; }

# ---- main -----------------------------------------------------------------------------------
[ -n "$CMD" ] || CMD=menu
[ "$(id -u)" -eq 0 ] || [ -n "$FILE" ] || say "note: not root - you can only manage your own keys"
pick_user
rc=0
case "$CMD" in
  list) do_list; rc=$? ;;
  add) do_add "$ARG"; rc=$? ;;
  remove) do_remove "$ARG"; rc=$? ;;
  perms) do_perms; rc=$? ;;
  diagnose) do_diagnose; rc=$? ;;
  restore) do_restore "$ARG"; rc=$? ;;
  menu)
    say "=== fixkeys $VERSION: authorized_keys recovery ==="
    while true; do
      say ""; say "--- $AK_FILE ($(count_keys) key(s)) ---"
      say "  1 list   2 add   3 remove   4 fix permissions   5 diagnose   6 restore a backup   q quit"
      printf 'choose [1]: ' >&4; IFS= read -r ch <&3 || { say ""; break; }   # end of input: quit, never loop
      case "${ch:-1}" in
        1) do_list || true ;; 2) do_add || true ;; 3) do_remove || true ;; 4) do_perms || true ;;
        5) do_diagnose || true ;; 6) do_restore || true ;;
        q|Q|6q|quit|7) say ""; say "Before closing this console, open a NEW terminal and check: ssh $AK_USER@<server-ip>"; break ;;
        *) say "  not a choice" ;;
      esac
    done ;;
esac
exit "$rc"
