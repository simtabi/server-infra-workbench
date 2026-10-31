# it-lib.sh - helpers shared by the Docker integration suites (sourced, not run).
#
# it_purge PROJECT... removes everything a compose project left behind: containers, then any container
# still attached to one of its networks (a TLS front, a restore-test container), then the networks and
# volumes. `compose down` alone cannot remove a network while a foreign container is attached; the leftover
# network keeps its fixed subnet, and the next suite that wants that subnet fails ("Pool overlaps").
# it_rm_net NAME... does the same for plain `docker network create` networks.
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
