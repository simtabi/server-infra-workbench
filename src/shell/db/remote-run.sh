#!/usr/bin/env bash
# =============================================================================
#  remote-run.sh - run docker-db-server-manager.sh on the DB server FROM YOUR
#  WORKSTATION, with a wrong-server guard
# =============================================================================
#  Run this on your laptop, not on a server. (The most common mistake in the
#  original session was running scp/ssh while already logged into the server:
#  ~/Downloads does not exist there and the server has no key to itself.)
#
#  It uploads the manager (and an optional config file) to the login user's
#  home, installs it to /root with sudo, refuses to continue unless the
#  expected private IP is present on the host, then runs the given commands.
#
#  USAGE
#    remote-run.sh --host user@203.0.113.10 -i ~/.ssh/db-key --expect-ip 10.0.0.5 \
#                  [--config db-server.conf] [--] reset --yes, verify, cron-install, env
#    remote-run.sh --host db-alias --expect-ip 10.0.0.5 -- doctor      (alias from ~/.ssh/config)
#    remote-run.sh -- engines status          (host, IP and key from SIWO_DB_* in the repo .env)
#    Commands are separated by commas; default: "install, cron-install, env".
#    Options go BEFORE `--`; everything after it is the manager's. So `--dry-run -- X` only prints
#    (connects to nothing) while `-- X --dry-run` is the manager's own plan (connects, needs sudo).
#
#  OPTIONS
#    --host H            user@host, user@ip or an ssh alias of the DB server
#                        (default: SIWO_DB_SSH_HOST in the env file)
#    -i, --identity KEY  private key for ssh/scp, used alone (-o IdentitiesOnly=yes)
#                        (default: SIWO_DB_SSH_IDENTITY in the env file; none = ssh's own choice)
#    --expect-ip IP      private IP that must be on the host ("skip" to disable)
#                        (default: SIWO_DB_PRIVATE_IP in the env file)
#    --env-file F        the settings file (default: .env at the repo root, or SIWO_ENV_FILE); read with
#                        awk, never sourced. Keep env files in the repo root (.env, .env.<client>)
#    --config FILE       override: install FILE as /etc/docker-db-server-manager.conf instead of the
#                        config generated from the env file
#    --no-config         install no config at all (the server keeps what it has)
#    --script FILE       manager to upload (default: next to this script)
#    --no-upload         use the manager already in /root (--config is still uploaded)
#    --sudo MODE         auto (default: probe with `sudo -n true` first) | nopasswd | prompt
#    --dry-run           print the ssh command and the remote commands, connect to nothing
#
#    --snapshot-with W   auto (default) | doctl | siwo | server | none  (workbench: old name of siwo)
#    -h, --help
#
#  SERVER CONFIG FROM THE ROOT .env
#    The root .env is the single source of local settings. Its SIWO_DB_<KEY> lines are the DB
#    server's settings (SIWO_DB_ENABLE_MYSQL=0 -> ENABLE_MYSQL=0, SIWO_DB_PG_DB=app -> PG_DB=app).
#    Unless --config or --no-config is given, remote-run writes them (prefix dropped) to a 600 temp
#    file and installs it as /etc/docker-db-server-manager.conf. Never sent: empty values, the
#    workstation-only keys (SIWO_DB_SSH_*, SIWO_DB_LOCAL_*) and anything named *PASSWORD*, *SECRET*,
#    *TOKEN* or *_KEY. On the server, /opt/db/.env is sourced after that file and wins for any key it
#    also holds; engines apply keeps the two in step.
#
#  SUDO
#    The manager runs as root. Before uploading anything, remote-run checks `sudo -n true` on the
#    host. Passwordless: it just runs. Otherwise it opens ssh -t and runs `sudo -v` first, so sudo
#    asks ONCE for the login user's password on the server's own prompt (for Ploi: the sudo password
#    from the "server provisioned" email; reset with `passwd ploi` from the DO console). No password
#    is ever put on a command line, in a file or in an environment variable. With no terminal (a
#    script, CI, a pipe) and a sudo that needs a password, it stops before connecting again.
#    Placeholders such as <db-alias> are refused: unquoted, the shell reads `<db-alias>` as a file
#    redirection and fails before this script starts (zsh: no such file or directory: db-alias).
#
#  UPGRADE + SNAPSHOT
#    Before uploading, the current /root manager and /etc config are kept as
#    *.prev so `upgrade` saves the OLD versions in its savepoint. If the command
#    list has `upgrade`/`apply`, a DigitalOcean snapshot is offered first, using
#    the first of these that works (auto):
#      1. doctl on this machine (doctl auth init)
#      2. bin/siwo do snapshot (DIGITALOCEAN_TOKEN or the workbench
#         credentials file, see: bin/siwo credentials)
#      3. a token on the server (/root/.config/digitalocean-token): the manager asks
#      4. none: the manager asks you to type CONTINUE to upgrade without one
#    After 1 or 2 the manager gets --snapshot-taken. No token is ever sent to
#    the server. --snapshot-with none passes --no-snapshot after you confirm.
#    Docs: docs/tools/remote-run.md
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
HOST="" EXPECT="" CONFIG="" NOCONF=0 GENCONF="" IDENT="" ENVF="${SIWO_ENV_FILE:-$ROOT/.env}" SCRIPT="$HERE/docker-db-server-manager.sh" UPLOAD=1 DRY=0 SNAPWITH=auto SUDO=auto
WORKBENCH="${WORKBENCH:-$HERE/../../../bin/siwo}"
die() { printf '!! %s\n' "$*" >&2; exit 1; }
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }
val() { # val OPTION VALUE: the value of an option, refusing a missing one or the next option (--host --expect-ip)
  [ -n "${2:-}" ] && [[ "$2" != -* ]] || die "$1 needs a value (got '${2:-nothing}'); see --help"
  printf '%s' "$2"
}
env_get() { # file key -> value of KEY=VALUE (quotes stripped, comments ignored); never sources the file
  [ -f "$1" ] || return 0
  awk -v k="$2" -F= '$0 !~ /^[[:space:]]*#/ && $1 == k { v = substr($0, length(k) + 2); sub(/[[:space:]]+#.*$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }' "$1"
}
placeholder() { # placeholder WHAT VALUE: refuse an unfilled <placeholder> from the docs or .env-example
  case "$2" in *"<"*|*">"*)
    die "$1 is still a placeholder: '$2'. Use the real value, e.g. --host ploi@203.0.113.10 (or an alias from ~/.ssh/config), --expect-ip 10.0.0.5, or set SIWO_DB_SSH_HOST / SIWO_DB_PRIVATE_IP in $ENVF. See docs/tools/remote-run.md#troubleshooting" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="$(val "$1" "${2:-}")"; shift 2 ;;
    --host=*)    HOST="${1#*=}"; shift ;;
    -i|--identity) IDENT="$(val "$1" "${2:-}")"; shift 2 ;;
    --identity=*) IDENT="${1#*=}"; shift ;;
    --expect-ip) EXPECT="$(val "$1" "${2:-}")"; shift 2 ;;
    --env-file)  ENVF="$(val "$1" "${2:-}")"; [ -f "$ENVF" ] || die "no such env file: $ENVF"; shift 2 ;;
    --config)    CONFIG="$(val "$1" "${2:-}")"; shift 2 ;;
    --no-config) NOCONF=1; shift ;;
    --script)    SCRIPT="$(val "$1" "${2:-}")"; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    --dry-run)   DRY=1; shift ;;
    --sudo)      SUDO="$(val "$1" "${2:-}")"; shift 2
                 case "$SUDO" in auto|nopasswd|prompt) ;; *) die "--sudo: auto, nopasswd or prompt" ;; esac ;;
    --snapshot-with) SNAPWITH="$(val "$1" "${2:-}")"; shift 2
                 case "$SNAPWITH" in auto|doctl|siwo|workbench|server|none) ;; *) die "--snapshot-with: auto, doctl, siwo, server or none" ;; esac
                 [ "$SNAPWITH" != siwo ] || SNAPWITH=workbench ;;   # one code path; siwo is the name users see
    -h|--help)   usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
# defaults from the workstation .env (only these keys; the file is never sourced), then the environment
HOST="${HOST:-${SIWO_DB_SSH_HOST:-$(env_get "$ENVF" SIWO_DB_SSH_HOST)}}"
EXPECT="${EXPECT:-${SIWO_DB_PRIVATE_IP:-$(env_get "$ENVF" SIWO_DB_PRIVATE_IP)}}"
EXPECT="${EXPECT:-$(env_get "$ENVF" SIWO_DB_EXPECTED_PRIVATE_IP)}"
IDENT="${IDENT:-${SIWO_DB_SSH_IDENTITY:-$(env_get "$ENVF" SIWO_DB_SSH_IDENTITY)}}"
[ -n "$HOST" ]   || die "no DB server: --host user@ip (or an ssh alias), or SIWO_DB_SSH_HOST in $ENVF"
[ -n "$EXPECT" ] || die "--expect-ip is required (or SIWO_DB_PRIVATE_IP in $ENVF; find it on the server: ip -4 -o addr show eth1)"
CMDS="${*:-install, cron-install, env}"
placeholder "--host" "$HOST"; placeholder "--expect-ip" "$EXPECT"; placeholder "--identity" "$IDENT"
placeholder "--config" "$CONFIG"; placeholder "the command list" "$CMDS"
[ "$EXPECT" = skip ] || [[ "$EXPECT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--expect-ip must be an IPv4 address or 'skip' (got '$EXPECT')"
case "$HOST" in *" "*|*@|@*) die "--host must be user@host, user@ip or an ssh alias (got '$HOST')" ;; esac
SSH_OPTS=(-o ConnectTimeout=15)
if [ -n "$IDENT" ]; then
  IDENT="${IDENT/#\~/$HOME}"
  case "$IDENT" in *.pub) die "--identity takes the PRIVATE key (got $IDENT); drop the .pub" ;; esac
  [ -f "$IDENT" ] || die "identity file not found: $IDENT"
  SSH_OPTS+=(-i "$IDENT" -o IdentitiesOnly=yes)
fi
[ "$NOCONF" = 0 ] || [ -z "$CONFIG" ] || die "--config and --no-config exclude each other"
# the server config: --config FILE, or generated from the SIWO_DB_* server keys of the env file
server_keys() { # envfile -> KEY=VALUE lines for the server (prefix dropped; secrets, empties, workstation keys left out)
  awk -F= '/^[[:space:]]*#/ || !/^SIWO_DB_[A-Z0-9_]+=/ { next }
    { k = $1; v = substr($0, length(k) + 2); sub(/[[:space:]]+#.*$/, "", v); s = v; gsub(/^["'\'']|["'\'']$/, "", s)
      if (s == "" || k ~ /^SIWO_DB_(SSH_|LOCAL_)/ || k ~ /(PASSWORD|SECRET|TOKEN|_KEY)/) next
      sub(/^SIWO_DB_/, "", k); print k "=" v }' "$1"
}
CONF_KEYS=""
if [ -z "$CONFIG" ] && [ "$NOCONF" = 0 ] && [ -f "$ENVF" ]; then
  GENCONF="$(mktemp "${TMPDIR:-/tmp}/siwo-db-conf.XXXXXX")"; chmod 600 "$GENCONF"; trap 'rm -f "$GENCONF"' EXIT
  { echo "# docker-db-server-manager config generated by remote-run.sh from $(basename "$ENVF") on $(date +%F). No secrets."
    server_keys "$ENVF"; } > "$GENCONF"
  CONF_KEYS="$(sed -n 's/^\([A-Z0-9_]*\)=.*/\1/p' "$GENCONF" | tr '\n' ' ')"
  bad="$(grep -E '^[A-Z0-9_]+=.*[<>]' "$GENCONF" | cut -d= -f1 | sed 's/^/SIWO_DB_/' | tr '\n' ' ' || true)"
  [ -z "$bad" ] || die "still <placeholders> in $ENVF: ${bad% } (fill them in, or pass --no-config)"
  if [ -n "$CONF_KEYS" ]; then CONFIG="$GENCONF"; else rm -f "$GENCONF"; GENCONF=""; fi
fi
# shellcheck disable=SC2029  # the remote command is built here on purpose
ssh_() { ssh "${SSH_OPTS[@]}" "$@"; }
LOGIN="the login user"; case "$HOST" in *@*) LOGIN="${HOST%%@*}" ;; esac
scp_() { scp "${SSH_OPTS[@]}" "$@"; }

# Refuse to run from a server that looks like the target (prompt says ploi@...).
if [ -d /home/ploi ] && [ "$(id -un)" = ploi ]; then
  die "you seem to be ON a Ploi server; run this from your workstation"
fi

M=/root/docker-db-server-manager.sh
C=/etc/docker-db-server-manager.conf
# Only a command whose FIRST word is upgrade/apply gets the snapshot offer and flag: a substring match
# also hit env-apply and pg-major-upgrade (which rejects --snapshot-taken), and sed tagged only the first.
is_upgrade() { local w; read -r w _ <<<"$1"; [ "$w" = upgrade ] || [ "$w" = apply ]; }
UPG=0; IFS=',' read -r -a parts <<< "$CMDS"   # UPG=1: an upgrade/apply that has no snapshot decision yet
for c in "${parts[@]}"; do
  is_upgrade "$c" && ! grep -qE -- '--(dry-run|no-snapshot|snapshot-taken|snapshot)( |$)' <<<"$c" && UPG=1
done
add_flag() { # add_flag FLAG: append FLAG to every upgrade/apply command
  local out="" c sep=""
  for c in "${parts[@]}"; do c="$(echo "$c" | xargs)"; is_upgrade "$c" && c+=" $1"; out+="$sep$c"; sep=", "; done
  CMDS="$out"; IFS=',' read -r -a parts <<< "$CMDS"
}
[ -z "$CONFIG" ] || [ -f "$CONFIG" ] || die "config not found: $CONFIG"
# staging names in the login home: hidden and distinct from $M, so a root login (home /root) does not
# "install" a file onto itself (rehearsal finding: install refused, 'are the same file')
STAGE_M=.vsw-upload-docker-db-server-manager.sh
STAGE_C=.vsw-upload-docker-db-server-manager.conf
# sudo: probe first (before anything is uploaded), so a password-protected sudo never meets a session that
# cannot show its prompt. rc 0 = passwordless, 255 = ssh itself failed, anything else = sudo wants a password.
if [ "$DRY" = 0 ] && [ "$SUDO" = auto ]; then
  set +e; err="$(ssh_ -T "$HOST" 'sudo -n true' </dev/null 2>&1)"; rc=$?; set -e
  case "$rc" in
    0)   SUDO=nopasswd ;;
    255) die "cannot ssh to $HOST: ${err:-no output}
   check: ssh${IDENT:+ -i $IDENT -o IdentitiesOnly=yes} $HOST true   (wrong key? pass -i KEY; wrong user? use user@ip)" ;;
    *)   SUDO=prompt ;;
  esac
fi
if [ "$DRY" = 0 ] && [ "$SUDO" = prompt ]; then
  [ -t 0 ] || die "sudo on $HOST needs the login user's password, and this session has no terminal to type it in.
   Run the same command in a terminal (Terminal, iTerm, an ssh session), not from a script, CI or a pipe.
   The password is typed into sudo's prompt on the server; it is never passed on a command line."
  echo "note: sudo on $HOST is not passwordless; it will ask ONCE for the sudo password of $LOGIN (sudo's own prompt over ssh -t)"
fi
if [ "$DRY" = 0 ]; then
  if [ "$UPLOAD" = 1 ]; then
    [ -f "$SCRIPT" ] || die "manager not found: $SCRIPT"
    scp_ -q "$SCRIPT" "$HOST:$STAGE_M"
  fi
  # the config goes up whenever it is given, also with --no-upload: installing the remote copy without
  # uploading it would silently install whatever stale file an earlier run left in the home directory
  [ -z "$CONFIG" ] || scp_ -q "$CONFIG" "$HOST:$STAGE_C"
fi

remote="set -e
if [ '$EXPECT' != skip ]; then
  ip -4 addr | grep 'inet ${EXPECT//./\\.}/' >/dev/null || { echo \"ABORT: this is \$(hostname), not the db server ($EXPECT missing)\"; exit 1; }
fi
echo \"OK: running on \$(hostname)\""
# a sudo that needs a password asks here, once, before anything changes (cached for the rest of this session)
[ "$SUDO" != prompt ] || remote+="
sudo -v -p '[sudo] password for %u on %h: ' || { echo 'ABORT: sudo refused; nothing changed'; exit 1; }"
[ "$UPLOAD" = 0 ] || remote+="
if sudo test -f $M; then sudo cp -p $M $M.prev; fi
sudo install -m 755 ~/$STAGE_M $M
rm -f ~/$STAGE_M"
[ -z "$CONFIG" ] || remote+="
if sudo test -f $C; then sudo cp -p $C $C.prev; fi
sudo install -m 600 ~/$STAGE_C $C
rm -f ~/$STAGE_C"
# optional snapshot from the workstation, before anything changes (fallback chain: see --help)
have_doctl()     { command -v doctl >/dev/null 2>&1 && doctl account get >/dev/null 2>&1; }
have_workbench() { [ -x "$WORKBENCH" ] && "$WORKBENCH" digitalocean account --json >/dev/null 2>&1; }
snap_name() { echo "db-pre-upgrade-$(date +%Y%m%d-%H%M%S)"; }
pick_snapshot_tool() {
  case "$SNAPWITH" in
    doctl)     have_doctl || die "--snapshot-with doctl: doctl is missing or not authenticated (doctl auth init)"; echo doctl ;;
    workbench) have_workbench || die "--snapshot-with siwo: no DigitalOcean token for bin/siwo (see: bin/siwo credentials)"; echo workbench ;;
    server|none) echo "$SNAPWITH" ;;
    auto) if have_doctl; then echo doctl; elif have_workbench; then echo workbench; else echo server; fi ;;
  esac
}
if [ "$UPG" = 1 ] && [ "$DRY" = 0 ]; then
  tool="$(pick_snapshot_tool)"
  case "$tool" in
    doctl|workbench)
      did="$(ssh_ "$HOST" 'curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/id' 2>/dev/null || true)"
      if [[ "$did" =~ ^[0-9]+$ ]]; then
        ans=""; [ -t 0 ] && read -r -p "Snapshot droplet $did with $tool before upgrading (recommended)? [Y/n] " ans
        case "$(printf '%s' "${ans:-y}" | tr '[:upper:]' '[:lower:]')" in
          y|yes) name="$(snap_name)"
                 if [ "$tool" = doctl ]; then
                   doctl compute droplet-action snapshot "$did" --snapshot-name "$name" --wait || die "snapshot failed; nothing changed"
                 else
                   "$WORKBENCH" digitalocean snapshot "$did" --name "$name" --wait --yes || die "snapshot failed; nothing changed"
                 fi
                 echo "snapshot taken with $tool: $name"
                 add_flag --snapshot-taken ;;
          n|no) echo "no snapshot from here; the server will ask" ;;
          *) die "answer y or n" ;;
        esac
      else echo "!! could not read the droplet id; the server will handle the snapshot question" >&2; fi ;;
    server)
      echo "note: no doctl (doctl auth init) and no DigitalOcean token for bin/siwo (bin/siwo credentials) here;"
      echo "      the server will use its own token, or ask you to type CONTINUE to upgrade without a snapshot" ;;
    none)
      ans=""; [ -t 0 ] && read -r -p "Upgrade WITHOUT a snapshot (rollback = saved files + verified backup)? Type 'skip': " ans
      [ "$ans" = skip ] || die "not confirmed; nothing changed (an unattended run needs an explicit --no-snapshot in the command)"
      add_flag --no-snapshot ;;
  esac
fi
remote_cmds=""
for c in "${parts[@]}"; do
  c="$(echo "$c" | xargs)"; [ -n "$c" ] || continue
  remote_cmds+="
sudo $M $c"
done
remote+="$remote_cmds"

TTY=-T; [ -t 0 ] && TTY=-t; [ "$SUDO" = prompt ] && TTY=-t
if [ "$DRY" = 1 ]; then
  printf -- '--- ssh: ssh'; printf ' %q' "${SSH_OPTS[@]}" "$TTY" "$HOST"; echo
  case "$SUDO" in
    auto)     echo "--- sudo: checked first with 'sudo -n true'; passwordless runs as is, otherwise ssh -t and sudo asks once" ;;
    nopasswd) echo "--- sudo: passwordless (--sudo nopasswd, not checked)" ;;
    prompt)   echo "--- sudo: asks once for the sudo password of $LOGIN (sudo -v over ssh -t)" ;;
  esac
  [ "$UPLOAD" = 0 ] || echo "--- upload: $SCRIPT -> $HOST:$STAGE_M"
  if [ -n "$GENCONF" ]; then echo "--- upload: config from $ENVF (keys: ${CONF_KEYS% }) -> $HOST:$STAGE_C (installed as $C)"
  elif [ -n "$CONFIG" ]; then echo "--- upload: $CONFIG -> $HOST:$STAGE_C (installed as $C)"
  else echo "--- config: none uploaded (the server keeps its own)"; fi
fi
echo "--- will run on $HOST:"
while IFS= read -r l; do printf '    %s\n' "$l"; done <<< "$remote"
[ "$DRY" = 0 ] || exit 0
ssh_ "$TTY" "$HOST" "$remote"
