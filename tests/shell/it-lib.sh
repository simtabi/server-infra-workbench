# it-lib.sh - helpers shared by the Docker integration suites (sourced, not run).
#
# it_purge PROJECT... removes everything a compose project left behind: containers, then any container
# still attached to one of its networks (a TLS front, a restore-test container), then the networks and
# volumes. `compose down` alone cannot remove a network while a foreign container is attached; the leftover
# network keeps its fixed subnet, and the next suite that wants that subnet fails ("Pool overlaps").
# it_rm_net NAME... does the same for plain `docker network create` networks.
#
# Per-run names and ports, so two `make it` runs (two worktrees, two agents) can share one Docker daemon:
#   VSW_IT_PREFIX=vswb make it      names start with vswb- / vswb_, ports shift by VSW_IT_PORT_OFFSET
# The default prefix `vsw` keeps the historic names and ports (offset 0). Any other prefix gets an offset of
# -10000, 11000 or 18000 derived from the prefix (set VSW_IT_PORT_OFFSET to pick one): the suites' ports
# (22535-29001) span less than 7000, so runs with different offsets never meet, and none lands in
# 30000-32767 (Kubernetes NodePorts on Docker Desktop) or the 49152+ ephemeral range. The run-suites leak guard only watches its
# own prefix, so a prefixed run never removes another run's objects. Suites that use it_name / it_port are
# prefix-aware (addons-it, garage-cluster-it); the others still use fixed vsw names, so run them in one
# run at a time (see tests/README.md#parallel-runs).
VSW_IT_PREFIX="${VSW_IT_PREFIX:-vsw}"
[[ "$VSW_IT_PREFIX" =~ ^vsw[a-z0-9]{0,12}$ ]] || { echo "VSW_IT_PREFIX must be 'vsw' plus up to 12 lowercase letters or digits" >&2; exit 2; }
if [ -z "${VSW_IT_PORT_OFFSET:-}" ]; then
  if [ "$VSW_IT_PREFIX" = vsw ]; then VSW_IT_PORT_OFFSET=0
  else offs=(-10000 11000 18000); VSW_IT_PORT_OFFSET="${offs[$(( $(printf '%s' "$VSW_IT_PREFIX" | cksum | cut -d' ' -f1) % 3 ))]}"; unset offs; fi
fi
[[ "$VSW_IT_PORT_OFFSET" =~ ^-?[0-9]+$ ]] && [ "$VSW_IT_PORT_OFFSET" -ge -20000 ] && [ "$VSW_IT_PORT_OFFSET" -le 20000 ] \
  || { echo "VSW_IT_PORT_OFFSET must be -20000..20000" >&2; exit 2; }
export VSW_IT_PREFIX VSW_IT_PORT_OFFSET
it_name() { printf '%s%s\n' "$VSW_IT_PREFIX" "$1"; }      # it_name -gcl-n1 -> vsw-gcl-n1 (or vswb-gcl-n1)
it_port() { echo $(($1 + VSW_IT_PORT_OFFSET)); }          # it_port 23900 -> 23900 (or 34900)
# it_ports_free PORT...: fail early when something on this machine already listens on a port the suite
# publishes (a desktop app on 127.0.0.1:30000 answered the Gotenberg checks with its own 404s)
it_ports_free() {
  local p busy=""
  for p in "$@"; do (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && busy="$busy $p"; done
  [ -z "$busy" ] || { echo "ports already in use on 127.0.0.1:$busy; pick another VSW_IT_PORT_OFFSET" >&2; return 1; }
}
# it_own: the leak-guard pattern for this run (all vsw* objects by default, only PREFIX- / PREFIX_ otherwise)
it_own() { if [ "$VSW_IT_PREFIX" = vsw ]; then echo '^vsw'; else echo "^${VSW_IT_PREFIX}[-_]"; fi; }
it_rm_net() {
  local n
  for n in "$@"; do
    docker network inspect -f '{{range $id, $c := .Containers}}{{$id}} {{end}}' "$n" 2>/dev/null | xargs -r docker rm -f
    docker network rm "$n"
  done >/dev/null 2>&1 || true
}
it_purge() {
  local p
  for p in "$@"; do
    docker ps -aq --filter "label=com.docker.compose.project=$p" | xargs -r docker rm -f >/dev/null 2>&1 || true
    # shellcheck disable=SC2046  # network ids never contain spaces
    it_rm_net $(docker network ls -q --filter "label=com.docker.compose.project=$p" 2>/dev/null)
    docker volume ls -q --filter "label=com.docker.compose.project=$p" | xargs -r docker volume rm >/dev/null 2>&1 || true
  done
}
# it_why FILE [N]: on a failure, show why before the tail: a long run's PROBLEM / !! / ERROR lines scroll
# out of `tail -N` (the 1.4 upgrade flake printed "doctor: 1 problems" without the problem itself).
it_why() {
  echo "---- problem lines in $(basename "$1"):"; grep -E 'PROBLEM|^!!|ERROR|FATAL|unhealthy' "$1" 2>/dev/null | head -20 || true
  echo "---- last ${2:-40} lines:"; tail -"${2:-40}" "$1" 2>/dev/null || true
}
