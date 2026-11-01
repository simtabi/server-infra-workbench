#!/usr/bin/env bash
# Live test: first-boot server setup on a real droplet, driven from this machine with --host
# (make live-test). One throwaway Ubuntu droplet in its own VPC. Checks what a container cannot:
#   * init.sh --host: the plan changes nothing; apply creates /swapfile (600, in fstab,
#     vm.swappiness=10) and installs Docker Engine + compose from Docker's apt repo with
#     daemon.json log rotation + live-restore; a second run has nothing to change
#   * swap and Docker survive a reboot (fstab, systemd enablement)
#   * harden.sh --host --check passes after init; status.sh --host --json reads the node
#   * --host leaves no copy of the tools behind (its temp dir is removed)
# WHY: server-it runs these tools in a container, where swapon, systemd and a real apt repo
# do not exist; the --host path (ssh + scp + sudo) only works against a real machine.
# Dry run by default; --yes spends (one s-1vcpu-1gb for under an hour, about $0.01). See docs/live-tests.md.
# shellcheck disable=SC2015
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/live/lib/live.sh
. tests/live/lib/live.sh
LIVE_TIMEOUT_MIN=40 LIVE_MAX_USD=0.25
live_args "$@"
live_begin server 1
S="$PWD/src/shell/server"
out() { echo "$LIVE_W/$1.out"; }

live_vpc_create; live_sshkey_create; live_firewall_create
live_droplets_create n1
[ -z "$(live_ssh n1 'swapon --show --noheadings')" ] && ! live_ssh n1 'command -v docker' >/dev/null \
  && live_ok "fresh droplet: no swap, no Docker" || live_fail "the image already has swap or Docker; the test proves nothing"

"$S/init.sh" --host n1 --role db --dry-run > "$(out plan)" 2>&1 </dev/null || { cat "$(out plan)"; live_fail "init --dry-run"; }
grep -q 'swap: create /swapfile' "$(out plan)" && grep -q "docker: add Docker's apt repo" "$(out plan)" && grep -q 'plan only' "$(out plan)" \
  && [ -z "$(live_ssh n1 'swapon --show --noheadings')" ] && live_ok "init --host --dry-run: plans swap + Docker, changes nothing" || { cat "$(out plan)"; live_fail "plan"; }

"$S/init.sh" --host n1 --role db --yes > "$(out apply)" 2>&1 </dev/null || { tail -40 "$(out apply)"; live_fail "init --host --yes"; }
grep -q 'swap: applied' "$(out apply)" && grep -q 'docker: applied' "$(out apply)" && live_ok "init --host --role db --yes applied" || { tail -40 "$(out apply)"; live_fail "apply"; }

check_node() { # $1 = label
  live_ssh n1 'swapon --show=NAME,SIZE --noheadings --bytes' > "$LIVE_W/swap.txt"
  awk '$1 == "/swapfile" && $2 >= 2000000000 {f=1} END {exit !f}' "$LIVE_W/swap.txt" \
    && [ "$(live_ssh n1 'stat -c %a /swapfile')" = 600 ] && live_ssh n1 "grep -qE '^/swapfile[[:space:]]+none[[:space:]]+swap' /etc/fstab" \
    && [ "$(live_ssh n1 'sysctl -n vm.swappiness')" = 10 ] \
    && live_ok "$1: /swapfile 2G active, 600, in fstab, vm.swappiness=10" || { cat "$LIVE_W/swap.txt"; live_fail "$1: swap"; }
  live_ssh n1 'systemctl is-active --quiet docker && systemctl is-enabled --quiet docker && docker compose version >/dev/null' \
    && live_ssh n1 "grep -q '\"live-restore\": true' /etc/docker/daemon.json && grep -q 'max-size' /etc/docker/daemon.json" \
    && live_ok "$1: Docker active + enabled, compose plugin, daemon.json log rotation + live-restore" || live_fail "$1: docker"
}
check_node "after init"
live_ssh n1 'docker run --rm hello-world' 2>/dev/null | grep -q 'Hello from Docker' && live_ok "Docker runs a container (image pulled from Docker Hub)" || live_fail "docker run"
live_ssh n1 "grep -q 'download.docker.com/linux/ubuntu' /etc/apt/sources.list.d/docker.list && test -s /etc/apt/keyrings/docker.asc" \
  && live_ok "Docker's apt repo, signed-by its key" || live_fail "docker apt source"

"$S/init.sh" --host n1 --role db --yes > "$(out again)" 2>&1 </dev/null && grep -q 'nothing to change' "$(out again)" \
  && live_ok "init a second time: nothing to change" || { tail -30 "$(out again)"; live_fail "idempotent"; }
"$S/harden.sh" --host n1 --role db --check > "$(out harden)" 2>&1 </dev/null && live_ok "harden --host --check: baseline in place" || { tail -30 "$(out harden)"; live_fail "harden check"; }
"$S/status.sh" --host n1 --json > "$(out status)" 2>"$LIVE_W/status.err" </dev/null || true
jq -e 'type == "object"' "$(out status)" >/dev/null && live_ok "status --host --json returns a JSON report" || { cat "$(out status)" "$LIVE_W/status.err"; live_fail "status"; }
[ -z "$(live_ssh n1 'find /tmp -mindepth 2 -maxdepth 2 -type d -name tool')" ] \
  && live_ok "--host removed its temp copies of the tools" || live_fail "tool copies left in /tmp"

live_ssh n1 'systemctl reboot' >/dev/null 2>&1 || true
sleep 20; up=0; for _ in $(seq 1 40); do live_ssh n1 'systemctl is-system-running --wait >/dev/null 2>&1; true' >/dev/null 2>&1 && { up=1; break; }; sleep 5; done
[ "$up" = 1 ] || live_fail "n1 did not come back after reboot"
live_ok "rebooted"
check_node "after reboot"
echo "server-live: $LIVE_PASS checks passed"
