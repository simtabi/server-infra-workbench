#!/usr/bin/env bash
# =============================================================================
#  harden.sh - safe baseline hardening for an Ubuntu droplet (db, web or base)
# =============================================================================
#  Prints a plan first; changes nothing until you confirm (--yes or type yes).
#  Every change: backup of the file it replaces, atomic write, validation
#  (sshd -t before any ssh reload), a lock and a line in the audit log.
#  Re-running is safe: items already in place report "ok" and are skipped.
#
#  ITEMS (pick with --only / --skip)
#    ssh         drop-in /etc/ssh/sshd_config.d/10-workbench.conf: keys only,
#                root by key only, MaxAuthTries 3, no X11/agent forwarding.
#                Refused when no authorized_keys entry exists (lockout guard).
#    updates     unattended-upgrades for security fixes (no automatic reboot;
#                reboots belong to `server update --reboot-window`)
#    fail2ban    sshd jail (5 tries -> 1h ban, systemd backend)
#    sysctl      /etc/sysctl.d/90-workbench.conf: syncookies, rp_filter,
#                no redirects or source routing, kptr/dmesg restrict
#    journald    cap the journal at 500M so logs can't fill the disk
#    firewall    ufw: allow OpenSSH (+ --allow ports), deny other inbound.
#                Only with --firewall, and never on a Ploi server (Ploi owns ufw).
#                Note: Docker-published ports bypass ufw; bind DB ports to the
#                private IP and use a DO cloud firewall (siwo do firewall-apply).
#    dockergroup members of the docker group other than root are reported (warn):
#                docker group = root on the host. --fix-docker-group removes them
#                (gpasswd -d, confirmed); DOCKER_GROUP_ALLOW=user,... exempts users.
#
#  USAGE
#    harden.sh                       plan only (same as --dry-run)
#    harden.sh --yes                 apply the plan
#    harden.sh --check               exit 1 when anything would change (cron/CI)
#    harden.sh --host db-1 --yes     run on db-1 over ssh (copies itself, uses sudo)
#
#  OPTIONS
#    --role db|web|base   tunes defaults (web/Ploi: firewall left to Ploi)
#    --only a,b  --skip a,b
#    --firewall           include the ufw item   --allow 80,443   extra ports
#    --root-login no      PermitRootLogin no (default: prohibit-password)
#    --fix-docker-group   remove non-allowed users from the docker group
#    --docker-allow a,b   users allowed in the docker group (same as DOCKER_GROUP_ALLOW)
#    --dry-run, -n  --yes, -y  --check  --host H  --quiet, -q  -h, --help
# =============================================================================
set -euo pipefail
TOOL=harden
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

ROLE=base ONLY="" SKIP="" FIREWALL=0 FIX_DOCKER=0 ALLOW="" ROOT_LOGIN=prohibit-password CHECK=0 HOST=""
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --skip) SKIP="${2:?}"; shift 2 ;;
    --firewall) FIREWALL=1; shift ;;
    --fix-docker-group) FIX_DOCKER=1; shift ;;
    --docker-allow) DOCKER_GROUP_ALLOW="${2:?}"; shift 2 ;;
    --allow) ALLOW="${2:?}"; shift 2 ;;
    --root-login) ROOT_LOGIN="${2:?}"; shift 2 ;;
    --check) CHECK=1; DRY=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --quiet|-q) export SIWO_QUIET=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --host) HOST="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
case "$ROLE" in db|web|base) ;; *) CODE=2 die "--role must be db, web or base" ;; esac
case "$ROOT_LOGIN" in no|prohibit-password) ;; *) CODE=2 die "--root-login must be no or prohibit-password" ;; esac
[[ -z "$ALLOW" || "$ALLOW" =~ ^[0-9]+(/(tcp|udp))?(,[0-9]+(/(tcp|udp))?)*$ ]] || CODE=2 die "--allow takes ports like 80,443,51820/udp"
if [ -n "$HOST" ]; then
  rest=(); skip_next=0
  for a in "${ARGS[@]}"; do if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi; [ "$a" = --host ] && { skip_next=1; continue; }; rest+=("$a"); done
  remote "$HOST" "$0" "${rest[@]+"${rest[@]}"}"; exit $?
fi

ITEMS="ssh updates fail2ban sysctl journald dockergroup"
DOCKER_GROUP_ALLOW="${DOCKER_GROUP_ALLOW:-}"
[[ -z "$DOCKER_GROUP_ALLOW" || "$DOCKER_GROUP_ALLOW" =~ ^[a-z_][a-z0-9_-]*(,[a-z_][a-z0-9_-]*)*$ ]] || CODE=2 die "DOCKER_GROUP_ALLOW takes user names like ploi,deploy"
[ "$FIREWALL" = 1 ] && ITEMS="$ITEMS firewall"
want() { local i="$1"
  [ -n "$ONLY" ] && { [[ ",$ONLY," == *",$i,"* ]] || return 1; }
  [[ ",$SKIP," == *",$i,"* ]] && return 1; return 0; }

# ---- desired state -----------------------------------------------------------
ssh_conf() { cat <<CONF
# Managed by server-infra-workbench harden.sh - edit there, not here.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin $ROOT_LOGIN
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
CONF
}
auto_conf() { printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n'; }
f2b_conf() { printf '# Managed by server-infra-workbench harden.sh\n[sshd]\nenabled = true\nbackend = systemd\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n'; }
sysctl_conf() { cat <<'CONF'
# Managed by server-infra-workbench harden.sh
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
CONF
}
journal_conf() { printf '# Managed by server-infra-workbench harden.sh\n[Journal]\nSystemMaxUse=500M\nMaxRetentionSec=1month\n'; }

F_SSH="$R/etc/ssh/sshd_config.d/10-workbench.conf"
F_AUTO="$R/etc/apt/apt.conf.d/20auto-upgrades"
F_F2B="$R/etc/fail2ban/jail.d/workbench-sshd.local"
F_SYSCTL="$R/etc/sysctl.d/90-workbench.conf"
F_JOURNAL="$R/etc/systemd/journald.conf.d/90-workbench.conf"

same() { [ -f "$1" ] && cmp -s "$1" <("$2"); }
legacy_apt_baks() { local f; for f in "$F_AUTO".bak.*; do [ -f "$f" ] && printf '%s\n' "$f"; done; return 0; }  # backups named before .<ts>.bak
pkg_ok() { have dpkg-query && dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep 'install ok installed' >/dev/null; }
docker_members() { # non-root members of the docker group that are not allowed, one per line
  local line u; line="$(grep -E '^docker:' "$R/etc/group" 2>/dev/null | head -1 || true)"
  [ -n "$line" ] || return 0
  for u in $(printf '%s' "${line##*:}" | tr ',' ' '); do
    [ "$u" = root ] && continue
    [[ ",$DOCKER_GROUP_ALLOW," == *",$u,"* ]] && continue
    printf '%s\n' "$u"
  done
}
key_count() { cat "$R"/root/.ssh/authorized_keys "$R"/home/*/.ssh/authorized_keys 2>/dev/null | grep -cE '^[^#]*(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-)' || true; }

PENDING=()
plan_item() { # plan_item NAME : prints the state, queues the item when it needs a change
  case "$1" in
    ssh)
      if same "$F_SSH" ssh_conf; then ok "ssh: keys-only drop-in in place"
      elif [ "$(key_count)" -eq 0 ]; then bad "ssh: no authorized_keys entry for root or any /home user - refusing (lockout guard)"
        why "turning off passwords with no key installed locks everyone out; add a key first (siwo keys server add)"
      else todo "ssh: write $F_SSH (passwords off, root $ROOT_LOGIN, MaxAuthTries 3), sshd -t, reload"; PENDING+=(ssh)
        why "password and keyboard-interactive logins are what bots brute-force"
      fi
      if [ -f "$R/etc/ssh/sshd_config" ] && ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/' "$R/etc/ssh/sshd_config"; then
        warn "ssh: sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf'; the drop-in would be ignored"
      fi ;;
    updates)
      if pkg_ok unattended-upgrades && same "$F_AUTO" auto_conf; then ok "updates: unattended security upgrades on"
      else todo "updates: install unattended-upgrades, write $F_AUTO"; PENDING+=(updates); why "security fixes land within a day without anyone logging in"; fi
      if [ -n "$(legacy_apt_baks)" ]; then todo "updates: rename $(legacy_apt_baks | wc -l | tr -d ' ') old $F_AUTO.bak.<ts> backup(s) to .<ts>.bak"
        why "apt prints an 'invalid filename extension' notice for every .bak.<ts> file in apt.conf.d; it skips *.bak quietly"
        [[ " ${PENDING[*]:-} " == *" updates "* ]] || PENDING+=(updates); fi ;;
    fail2ban)
      if pkg_ok fail2ban && same "$F_F2B" f2b_conf; then ok "fail2ban: sshd jail on"
      else todo "fail2ban: install, write $F_F2B, restart"; PENDING+=(fail2ban); why "bans IPs that keep failing ssh; cuts log noise and brute-force attempts"; fi ;;
    sysctl)
      if same "$F_SYSCTL" sysctl_conf; then ok "sysctl: network hardening in place"
      else todo "sysctl: write $F_SYSCTL, sysctl --system"; PENDING+=(sysctl); why "drops spoofed and redirected packets; hides kernel pointers"; fi ;;
    journald)
      if same "$F_JOURNAL" journal_conf; then ok "journald: capped at 500M"
      else todo "journald: write $F_JOURNAL, restart journald"; PENDING+=(journald); why "an uncapped journal can fill a small droplet's disk and stop the DB"; fi ;;
    dockergroup)
      local m; m="$(docker_members | tr '\n' ' ')"; m="${m% }"
      if ! grep -qE '^docker:' "$R/etc/group" 2>/dev/null; then ok "dockergroup: no docker group on this host"
      elif [ -z "$m" ]; then ok "dockergroup: only root${DOCKER_GROUP_ALLOW:+ and allowed ($DOCKER_GROUP_ALLOW)} in the docker group"
      elif [ "$FIX_DOCKER" = 1 ]; then todo "dockergroup: remove $m from the docker group (gpasswd -d)"; PENDING+=(dockergroup)
        why "the docker group can start a privileged container and own the host; deploy users don't need it"
      else warn "dockergroup: $m in the docker group (root-equivalent); fix: --fix-docker-group, or allow: --docker-allow ${m// /,}"
        why "anyone in the docker group can mount / into a container; a leaked deploy key becomes root"
      fi ;;
    firewall)
      if ploi_managed; then warn "firewall: Ploi server - skipped (manage rules in Ploi > Network)"; return 0; fi
      if have ufw && ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then ok "firewall: ufw active (review: ufw status verbose)"
      else todo "firewall: ufw allow OpenSSH${ALLOW:+ + $ALLOW}, default deny incoming, enable"; PENDING+=(firewall); why "defence in depth behind the DO cloud firewall"; fi ;;
  esac
}

apply_item() {
  case "$1" in
    ssh)
      [ "$(key_count)" -gt 0 ] || die "no authorized key - refusing"
      prev=""; [ -f "$F_SSH" ] && { prev="$(mktemp)"; cp -p "$F_SSH" "$prev"; }
      ssh_conf | write_file "$F_SSH" 644
      if have sshd && ! err="$(sshd -t 2>&1)"; then
        if [ -n "$prev" ]; then mv "$prev" "$F_SSH"; else rm -f "$F_SSH"; fi
        printf '%s\n' "$err" >&2; die "sshd -t failed; drop-in rolled back, ssh not reloaded"
      fi
      [ -z "$prev" ] || rm -f "$prev"
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "reload ssh by hand: systemctl reload ssh"
      say "        keep this session open and test a NEW ssh login before closing it" ;;
    updates)
      pkg_ok unattended-upgrades || DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades
      auto_conf | write_file "$F_AUTO" 644
      local f; while IFS= read -r f; do [ -n "$f" ] && mv "$f" "$F_AUTO.${f##*.bak.}.bak"; done < <(legacy_apt_baks) ;;
    fail2ban)
      pkg_ok fail2ban || DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban
      f2b_conf | write_file "$F_F2B" 644; systemctl restart fail2ban 2>/dev/null || true ;;
    sysctl) sysctl_conf | write_file "$F_SYSCTL" 644; sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported errors" ;;
    journald) journal_conf | write_file "$F_JOURNAL" 644; systemctl restart systemd-journald 2>/dev/null || true ;;
    dockergroup)
      local u
      for u in $(docker_members); do
        if [ -z "$R" ] && have gpasswd; then gpasswd -d "$u" docker >/dev/null
        else # sysroot (tests) or no gpasswd: same edit on the file, refused unless it is whole
          local t; t="$(mktemp)"
          awk -F: -v OFS=: -v u="$u" '$1=="docker"{n=split($4,a,",");o="";for(i=1;i<=n;i++){if(a[i]==u)continue;if(o!="")o=o ",";o=o a[i]};$4=o}{print}' "$R/etc/group" > "$t" \
            && [ "$(wc -l < "$t")" = "$(wc -l < "$R/etc/group")" ] || { rm -f "$t"; die "could not edit $R/etc/group; nothing changed"; }
          write_file "$R/etc/group" 644 < "$t"; rm -f "$t"
        fi
        say "        removed $u from docker (takes effect at that user's next login; running sessions keep it)"
      done ;;
    firewall)
      have ufw || DEBIAN_FRONTEND=noninteractive apt-get install -y -q ufw
      ufw allow OpenSSH >/dev/null
      if [ -n "$ALLOW" ]; then IFS=, read -r -a ports <<<"$ALLOW"; for p in "${ports[@]}"; do ufw allow "$p" >/dev/null; done; fi
      ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null; ufw --force enable >/dev/null ;;
  esac
  ok "$1: applied"; audit applied "item=$1 role=$ROLE"
}

# ---- run -------------------------------------------------------------------------
say "harden plan (role $ROLE$(ploi_managed && echo ', Ploi server')):"
for i in $ITEMS; do want "$i" && plan_item "$i"; done
if [ "$FIREWALL" = 0 ] && ! ploi_managed && have ufw && ufw status 2>/dev/null | grep 'Status: inactive' >/dev/null; then
  say "  note  ufw is inactive and not managed without --firewall; the DO cloud firewall (siwo do firewall-apply) is the"
  say "        filter then. For ufw too: rerun with --firewall --allow <ports> (a Garage node also needs its RPC port from the VPC)"
fi
if have docker && docker ps --format '{{.Ports}}' 2>/dev/null | grep '0\.0\.0\.0:' >/dev/null; then
  warn "docker publishes a port on 0.0.0.0 - Docker bypasses ufw; bind to the private IP"
fi
if [ "${#PENDING[@]}" -eq 0 ]; then summary; say "nothing to change"; exit $(( c_fail > 0 ? 1 : 0 )); fi
if [ "$DRY" = 1 ]; then summary; say "plan only - rerun with --yes to apply"; exit "$CHECK"; fi
[ "$(id -u)" -eq 0 ] || [ -n "$R" ] || die "run as root (sudo)"
lock
confirm "apply ${#PENDING[@]} hardening change(s): ${PENDING[*]}"
audit confirmed "items=${PENDING[*]} role=$ROLE"
for i in "${PENDING[@]}"; do apply_item "$i"; done
summary
audit succeeded "items=${PENDING[*]}"
