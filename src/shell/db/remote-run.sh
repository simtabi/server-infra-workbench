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
#    remote-run.sh --host db-alias --expect-ip 10.0.0.5 [--config db-server.conf] \
#                  [--] reset --yes, verify, cron-install, env
#    Commands are separated by commas; default: "install, cron-install, env".
#
#  OPTIONS
#    --host ALIAS        ssh alias / user@host of the DB server (required)
#    --expect-ip IP      private IP that must be on the host (required; "skip" to disable)
#    --config FILE       local config to install as /etc/docker-db-server-manager.conf
#    --script FILE       manager to upload (default: next to this script)
#    --no-upload         use the manager already in /root (--config is still uploaded)
#    --dry-run           print the remote commands, connect to nothing
#
#    --snapshot-with W   auto (default) | doctl | workbench | server | none
#    -h, --help
#
#  UPGRADE + SNAPSHOT
#    Before uploading, the current /root manager and /etc config are kept as
#    *.prev so `upgrade` saves the OLD versions in its savepoint. If the command
#    list has `upgrade`/`apply`, a DigitalOcean snapshot is offered first, using
#    the first of these that works (auto):
#      1. doctl on this machine (doctl auth init)
#      2. bin/workbench do snapshot (DIGITALOCEAN_TOKEN or the workbench
#         credentials file, see: bin/workbench credentials)
#      3. a token on the server (/root/.config/digitalocean-token): the manager asks
#      4. none: the manager asks you to type CONTINUE to upgrade without one
#    After 1 or 2 the manager gets --snapshot-taken. No token is ever sent to
#    the server. --snapshot-with none passes --no-snapshot after you confirm.
#  sudo prompts once (ssh -t). Use the ploi user's sudo password from Ploi's
#  "server provisioned" email; reset it with `passwd ploi` from the DO console.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="" EXPECT="" CONFIG="" SCRIPT="$HERE/docker-db-server-manager.sh" UPLOAD=1 DRY=0 SNAPWITH=auto
WORKBENCH="${WORKBENCH:-$HERE/../../../bin/workbench}"
die() { printf '!! %s\n' "$*" >&2; exit 1; }
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="${2:?}"; shift 2 ;;
    --expect-ip) EXPECT="${2:?}"; shift 2 ;;
    --config)    CONFIG="${2:?}"; shift 2 ;;
    --script)    SCRIPT="${2:?}"; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    --dry-run)   DRY=1; shift ;;
    --snapshot-with) SNAPWITH="${2:?}"; shift 2
                 case "$SNAPWITH" in auto|doctl|workbench|server|none) ;; *) die "--snapshot-with: auto, doctl, workbench, server or none" ;; esac ;;
    -h|--help)   usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
[ -n "$HOST" ]   || die "--host is required"
[ -n "$EXPECT" ] || die "--expect-ip is required (find it on the server: ip -4 -o addr show eth1)"
CMDS="${*:-install, cron-install, env}"

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
if [ "$DRY" = 0 ]; then
  if [ "$UPLOAD" = 1 ]; then
    [ -f "$SCRIPT" ] || die "manager not found: $SCRIPT"
    scp -q "$SCRIPT" "$HOST:$STAGE_M"
  fi
  # the config goes up whenever it is given, also with --no-upload: installing the remote copy without
  # uploading it would silently install whatever stale file an earlier run left in the home directory
  [ -z "$CONFIG" ] || scp -q "$CONFIG" "$HOST:$STAGE_C"
fi

remote="set -e
if [ '$EXPECT' != skip ]; then
  ip -4 addr | grep 'inet ${EXPECT//./\\.}/' >/dev/null || { echo \"ABORT: this is \$(hostname), not the db server ($EXPECT missing)\"; exit 1; }
fi
echo \"OK: running on \$(hostname)\""
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
    workbench) have_workbench || die "--snapshot-with workbench: no DigitalOcean token for bin/workbench (see: bin/workbench credentials)"; echo workbench ;;
    server|none) echo "$SNAPWITH" ;;
    auto) if have_doctl; then echo doctl; elif have_workbench; then echo workbench; else echo server; fi ;;
  esac
}
if [ "$UPG" = 1 ] && [ "$DRY" = 0 ]; then
  tool="$(pick_snapshot_tool)"
  case "$tool" in
    doctl|workbench)
      did="$(ssh "$HOST" 'curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/id' 2>/dev/null || true)"
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
      echo "note: no doctl (doctl auth init) and no DigitalOcean token for bin/workbench (bin/workbench credentials) here;"
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

echo "--- will run on $HOST:"
while IFS= read -r l; do printf '    %s\n' "$l"; done <<< "$remote"
[ "$DRY" = 0 ] || exit 0
ssh -t "$HOST" "$remote"
