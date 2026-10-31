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
#    --no-upload         use the copy already in /root
#    --dry-run           print the remote commands, connect to nothing
#
#  UPGRADE + SNAPSHOT
#    Before uploading, the current /root manager and /etc config are kept as
#    *.prev so `upgrade` saves the OLD versions in its savepoint. If the command
#    list has `upgrade`/`apply` and doctl is configured here (doctl auth init),
#    you are offered a DigitalOcean snapshot (doctl ... --wait) first; the
#    manager then gets --snapshot-taken. No token is ever sent to the server.
#    -h, --help
#  sudo prompts once (ssh -t). Use the ploi user's sudo password from Ploi's
#  "server provisioned" email; reset it with `passwd ploi` from the DO console.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="" EXPECT="" CONFIG="" SCRIPT="$HERE/docker-db-server-manager.sh" UPLOAD=1 DRY=0
die() { printf '!! %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^# =====/{/^# =====/d;s/^#  \{0,1\}//;p}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="${2:?}"; shift 2 ;;
    --expect-ip) EXPECT="${2:?}"; shift 2 ;;
    --config)    CONFIG="${2:?}"; shift 2 ;;
    --script)    SCRIPT="${2:?}"; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    --dry-run)   DRY=1; shift ;;
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
case ",$CMDS," in *upgrade*|*apply*) UPG=1 ;; *) UPG=0 ;; esac
if [ "$UPLOAD" = 1 ] && [ "$DRY" = 0 ]; then
  [ -f "$SCRIPT" ] || die "manager not found: $SCRIPT"
  scp -q "$SCRIPT" "$HOST:docker-db-server-manager.sh"
  [ -z "$CONFIG" ] || scp -q "$CONFIG" "$HOST:docker-db-server-manager.conf"
fi

remote="set -e
if [ '$EXPECT' != skip ]; then
  ip -4 addr | grep -q 'inet ${EXPECT//./\\.}/' || { echo \"ABORT: this is \$(hostname), not the db server ($EXPECT missing)\"; exit 1; }
fi
echo \"OK: running on \$(hostname)\""
[ "$UPLOAD" = 0 ] || remote+="
if sudo test -f $M; then sudo cp -p $M $M.prev; fi
if sudo test -f $C; then sudo cp -p $C $C.prev; fi
sudo install -m 755 ~/docker-db-server-manager.sh $M"
[ -z "$CONFIG" ] || remote+="
sudo install -m 600 ~/docker-db-server-manager.conf /etc/docker-db-server-manager.conf"
# optional snapshot from the workstation (doctl), before anything changes
if [ "$UPG" = 1 ] && [ "$DRY" = 0 ] && ! grep -qE -- '--(dry-run|no-snapshot|snapshot-taken|snapshot)' <<<"$CMDS"; then
  if command -v doctl >/dev/null 2>&1 && doctl account get >/dev/null 2>&1; then
    did="$(ssh "$HOST" 'curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/id' 2>/dev/null || true)"
    if [[ "$did" =~ ^[0-9]+$ ]]; then
      ans=""; [ -t 0 ] && read -r -p "Snapshot droplet $did with doctl before upgrading (recommended)? [Y/n] " ans
      case "$(printf '%s' "${ans:-y}" | tr '[:upper:]' '[:lower:]')" in
        y|yes) doctl compute droplet-action snapshot "$did" --snapshot-name "db-pre-upgrade-$(date +%Y%m%d-%H%M%S)" --wait \
                 || die "snapshot failed; nothing changed"
               CMDS="$(sed -E 's/(upgrade|apply)/\1 --snapshot-taken/' <<<"$CMDS")" ;;
        n|no) echo "no snapshot from here; the server will ask" ;;
        *) die "answer y or n" ;;
      esac
    else echo "!! could not read the droplet id; the server will handle the snapshot question" >&2; fi
  else
    echo "note: doctl not configured here (brew install doctl && doctl auth init) - the server will ask about a snapshot"
  fi
fi
IFS=',' read -r -a parts <<< "$CMDS"; remote_cmds=""
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
