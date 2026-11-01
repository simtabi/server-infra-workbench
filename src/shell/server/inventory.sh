#!/usr/bin/env bash
# =============================================================================
#  inventory.sh - record what a server is: OS, size, services, ports, versions
# =============================================================================
#  Read-only on the server (except --install-cron). Never reads .env values,
#  keys or passwords: only names, versions, counts and states.
#
#  OUTPUT  a flat, sorted `key<TAB>value` list (inventory.txt) that diffs
#          cleanly, plus inventory.json and inventory.md made from it.
#
#  USAGE
#    inventory.sh                          markdown to stdout
#    inventory.sh --json                   JSON to stdout
#    inventory.sh --out /var/lib/server-infra-workbench/inventory
#                                          write txt/json/md (+ dated copy, diff vs last)
#    inventory.sh --host db-1 --pull [--client acme]
#        run on db-1 over ssh, save to local/<client>/inventory/db-1/ (gitignored;
#        ./inventory/db-1/ without --client) and print what changed since last time
#    inventory.sh --install-cron [--yes]   daily 05:17 run into /var/lib/server-infra-workbench/inventory
#
#  OPTIONS
#    --json  --md  --out DIR  --host H  --pull  --client C  --install-cron
#    --dry-run, -n  --yes, -y  -h, --help
# =============================================================================
set -euo pipefail
TOOL=inventory
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/shell/lib/common.sh
. "$HERE/../lib/common.sh"
# usage: the boxed header (between the 1st and 3rd ===== lines). A sed range `2,/=====/` stopped at the
# title box, so --help printed one line; awk counts the rules instead.
usage() { awk '/^# =====/{if(++r==3)exit; next} NR>1{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

FMT=md OUT="" HOST="" PULL=0 CLIENT="" CRON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FMT=json; shift ;;
    --md) FMT=md; shift ;;
    --txt) FMT=txt; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --host) HOST="${2:?}"; shift 2 ;;
    --pull) PULL=1; shift ;;
    --client) CLIENT="${2:?}"; shift 2 ;;
    --install-cron) CRON=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) CODE=2 die "unknown option: $1 (see --help)" ;;
  esac
done
[[ -z "$CLIENT" || "$CLIENT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || CODE=2 die "--client: lower-case letters, digits, - and _"
[ "$PULL" = 0 ] || [ -n "$HOST" ] || CODE=2 die "--pull needs --host"

# ---- collect (key<TAB>value, one fact per line) -------------------------------------------
fact() { printf '%s\t%s\n' "$1" "$(printf '%s' "${2:-}" | tr '\t\n' '  ' | sed 's/[[:space:]]*$//')"; }
ver() { "$@" 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true; }
pkg_ok() { have dpkg-query && dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep 'install ok installed' >/dev/null; }
collect() { # best effort: a missing tool or file is a "?" fact, never an abort (runs in its own subshell)
  set +e +o pipefail
  local os_name kernel n=0 l
  os_name="$(sed -n 's/^PRETTY_NAME=//p' "$R/etc/os-release" 2>/dev/null | tr -d '"')"
  kernel="$(uname -r 2>/dev/null || echo '?')"
  fact host.name "$(hostname 2>/dev/null || echo '?')"
  fact os.name "${os_name:-unknown}"; fact os.kernel "$kernel"
  fact os.timezone "$(timedatectl show -p Timezone --value 2>/dev/null || cat "$R/etc/timezone" 2>/dev/null || echo '?')"
  fact os.reboot_required "$([ -f "$R/var/run/reboot-required" ] && echo yes || echo no)"
  fact os.upgradable "$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)"
  fact size.cpus "$(nproc 2>/dev/null || echo '?')"
  fact size.mem_mb "$(awk '/^MemTotal:/ {print int($2/1024)}' "$R/proc/meminfo" 2>/dev/null || echo '?')"
  fact size.swap_mb "$(awk '/^SwapTotal:/ {print int($2/1024)}' "$R/proc/meminfo" 2>/dev/null || echo '?')"
  fact size.disk_root "$(df -Pk / 2>/dev/null | awk 'NR==2 {printf "%dG total, %s used", $2/1048576, $5}')"
  while read -r l; do [ -n "$l" ] && { n=$((n + 1)); fact "net.ipv4.$n" "$l"; }; done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2" "$4}')
  while read -r l; do [ -n "$l" ] && fact "net.listen.$l" tcp; done < <(ss -Hltn 2>/dev/null | awk '{print $4}' | sort -u)
  fact role.ploi "$(ploi_managed && echo yes || echo no)"
  if [ -d "$R/home/ploi" ]; then
    n=0; for l in "$R"/home/ploi/*/; do l="$(basename "$l")"; case "$l" in *-shared|*'*'*) continue ;; esac
      n=$((n + 1)); fact "sites.$l" "$([ -f "$R/home/ploi/$l/artisan" ] || [ -f "$R/home/ploi/$l/current/artisan" ] && echo laravel || echo site)"; done
  fi
  have php && fact ver.php "$(ver php -v)"
  have nginx && fact ver.nginx "$(ver nginx -v)"
  have docker && fact ver.docker "$(ver docker --version)"
  have docker && docker compose version >/dev/null 2>&1 && fact ver.compose "$(ver docker compose version)"
  [ -f "$R/root/docker-db-server-manager.sh" ] && fact ver.db_manager "$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$R/root/docker-db-server-manager.sh" | head -1)"
  if have docker; then
    n=0; while IFS='|' read -r name image status; do [ -n "$name" ] || continue
      fact "containers.$name" "$image ($(sed -E 's/ \(healthy\)/ healthy/; s/Up [^(]*/up/' <<<"$status"))"; done \
      < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null | sort)
  fi
  local s; for s in ssh fail2ban unattended-upgrades docker nginx cron; do
    have systemctl && fact "svc.$s" "$(systemctl is-active "$s" 2>/dev/null | head -1 || true)"; done
  fact sec.ssh_dropin "$([ -f "$R/etc/ssh/sshd_config.d/10-workbench.conf" ] && echo yes || echo no)"
  fact sec.ufw "$(have ufw && ufw status 2>/dev/null | sed -n 's/^Status: //p' | head -1 || echo absent)"
  fact sec.fail2ban "$(pkg_ok fail2ban && echo installed || echo absent)"
  fact sec.authorized_keys "$(cat "$R"/root/.ssh/authorized_keys "$R"/home/*/.ssh/authorized_keys 2>/dev/null | grep -cE '^[^#]*(ssh-|ecdsa-|sk-)' || true)"
}

to_json() { # flat facts -> {"collected": "...", "facts": {...}}
  printf '{\n  "collected": "%s",\n  "facts": {\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  awk -F'\t' '{ k=$1; v=$2; gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v); gsub(/\\/,"\\\\",k); gsub(/"/,"\\\"",k)
    printf "%s    \"%s\": \"%s\"", (NR>1 ? ",\n" : ""), k, v } END { print "" }'
  printf '  }\n}\n'
}
to_md() {
  # shellcheck disable=SC2016  # literal backticks in markdown
  printf '# Inventory: %s\n\nCollected %s by server-infra-workbench `server inventory` (no secrets).\n' \
    "$(awk -F'\t' '$1=="host.name"{print $2}' "$1")" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  awk -F'\t' '{ split($1, p, "."); sec=p[1]; key=substr($1, length(sec)+2)
    if (sec != last) { printf "\n## %s\n\n| Key | Value |\n|---|---|\n", sec; last=sec }
    v=$2; gsub(/\|/, "\\|", v); printf "| %s | %s |\n", key, v }' "$1"
}

# ---- remote + pull -------------------------------------------------------------------------
if [ -n "$HOST" ]; then
  if [ "$PULL" = 0 ]; then
    rest=(); [ "$FMT" = json ] && rest+=(--json); [ "$CRON" = 1 ] && rest+=(--install-cron); [ "$YES" = 1 ] && rest+=(--yes); [ "$DRY" = 1 ] && rest+=(--dry-run)
    [ -z "$OUT" ] || rest+=(--out "$OUT"); remote "$HOST" "$0" "${rest[@]+"${rest[@]}"}"; exit $?
  fi
  root="${SIWO_REPO_ROOT:-$(cd "$HERE/../../.." && pwd)}"   # tests point this at a temp dir
  dest="$root/${CLIENT:+local/$CLIENT/}inventory/$HOST"; mkdir -p "$dest"; chmod 700 "$dest"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  REMOTE_NOTTY=1 remote "$HOST" "$0" --txt > "$tmp" || die "inventory on $HOST failed (needs passwordless sudo for a non-interactive run)"
  tr -d '\r' < "$tmp" | awk -F'\t' 'NF >= 2' | LC_ALL=C sort > "$tmp.f"; mv "$tmp.f" "$tmp"
  [ -s "$tmp" ] || die "no facts came back from $HOST"
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [ -f "$dest/inventory.txt" ]; then
    if diff -u "$dest/inventory.txt" "$tmp" > "$dest/changes-$stamp.diff"; then rm -f "$dest/changes-$stamp.diff"; say "$HOST: no changes since the last inventory"
    else say "$HOST: changes since the last inventory:"; grep -E '^[+-][^+-]' "$dest/changes-$stamp.diff" | sed 's/^/  /'; fi
  else say "$HOST: first inventory"; fi
  (umask 077; cp "$tmp" "$dest/inventory.txt"; cp "$tmp" "$dest/inventory-$stamp.txt"
   to_json < "$tmp" > "$dest/inventory.json"; to_md "$tmp" > "$dest/inventory.md")
  say "saved: ${dest#"$root"/}/inventory.{txt,json,md} (+ dated copy)"
  exit 0
fi

# ---- cron ----------------------------------------------------------------------------------
if [ "$CRON" = 1 ]; then
  lib="$R/usr/local/lib/server-infra-workbench" cronf="$R/etc/cron.d/vsw-inventory"
  invdir="$(siw_path "$R/var/lib/server-infra-workbench/inventory")"; invdir="${invdir#"$R"}"   # keep a pre-rename history
  say "install: copy this tool to /usr/local/lib/server-infra-workbench/server/, write /etc/cron.d/vsw-inventory (daily 05:17)"
  [ "$DRY" = 1 ] && { say "plan only - rerun with --yes"; exit 0; }
  [ "$(id -u)" -eq 0 ] || [ -n "$R" ] || die "run as root (sudo)"
  lock; confirm "install the daily inventory cron"
  install -d -m 755 "$lib/server" "$lib/lib"
  install -m 755 "$0" "$lib/server/inventory.sh"; install -m 644 "$HERE/../lib/common.sh" "$lib/lib/common.sh"; install -m 644 "$HERE/../lib/progress.sh" "$lib/lib/progress.sh"
  printf '# Managed by server-infra-workbench inventory.sh\nSHELL=/bin/bash\n17 5 * * * root /usr/local/lib/server-infra-workbench/server/inventory.sh --out %s >/dev/null 2>&1\n' "$invdir" \
    | write_file "$cronf" 644
  audit applied "cron=/etc/cron.d/vsw-inventory"; ok "daily inventory cron installed"; exit 0
fi

# ---- local run -------------------------------------------------------------------------------
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
collect | LC_ALL=C sort > "$tmp"
[ -s "$tmp" ] || die "inventory collected nothing"
if [ -n "$OUT" ]; then
  d="$R$OUT"; mkdir -p "$d"; chmod 700 "$d"; stamp="$(date +%Y%m%d-%H%M%S)"
  if [ -f "$d/inventory.txt" ] && ! diff -u "$d/inventory.txt" "$tmp" > "$d/changes-$stamp.diff"; then
    audit changed "out=$OUT diff=changes-$stamp.diff"; say "changes since the last inventory: $OUT/changes-$stamp.diff"
  else rm -f "$d/changes-$stamp.diff"; fi
  (umask 077; cp "$tmp" "$d/inventory.txt"; cp "$tmp" "$d/inventory-$stamp.txt"; to_json < "$tmp" > "$d/inventory.json"; to_md "$tmp" > "$d/inventory.md")
  find "$d" -name 'inventory-*.txt' -mtime +90 -delete 2>/dev/null || true
  say "saved: $OUT/inventory.{txt,json,md}"; exit 0
fi
case "$FMT" in txt) cat "$tmp" ;; json) to_json < "$tmp" ;; md) to_md "$tmp" ;; esac
