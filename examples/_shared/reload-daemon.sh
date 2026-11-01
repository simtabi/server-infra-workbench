#!/usr/bin/env bash
# examples/_shared/reload-daemon.sh - restart app daemons after Ploi activated a new release, one port at a time.
#
#   reload-daemon.sh [--signal TERM] [--timeout 60] PORT HEALTH_PATH [PORT HEALTH_PATH]...
#   e.g. reload-daemon.sh 8000 /healthz            (in Ploi's post-deploy script, as the ploi user)
#
# Why: a daemon keeps running the release it started in; the `current` symlink moving does not change a running
# process. So after activation each daemon gets a signal (default TERM: finish in-flight requests, exit),
# Supervisor starts it again from the new release, and this waits until http://127.0.0.1:PORT/HEALTH_PATH
# answers 2xx/3xx from a NEW process before moving to the next port. With two daemons on two ports behind one
# Nginx upstream (README of the example), the site stays up throughout. Exit 1 if a port does not come back.
# Finds the process by the port it listens on (ss), never by name, and only among this user's processes.
set -euo pipefail
sig=TERM timeout=60
die() { printf 'reload-daemon: %s\n' "$1" >&2; exit "${2:-1}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --signal) sig="${2:?}"; shift 2 ;;
    --timeout) timeout="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] && [ $(($# % 2)) -eq 0 ] || die "usage: reload-daemon.sh [--signal S] [--timeout N] PORT HEALTH_PATH [...]" 2
command -v ss > /dev/null || die "ss not found (iproute2)"

listeners() { # PIDs (this user's) listening on 127.0.0.1:PORT
  ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -un
}
roots() { # the parent(s) among the listeners: Gunicorn/Puma/uvicorn masters share the socket with workers
  local all p pp; all=" $(listeners "$1" | tr '\n' ' ') "
  for p in $all; do pp="$(ps -o ppid= -p "$p" | tr -d ' ')"; case "$all" in *" $pp "*) ;; *) echo "$p" ;; esac; done
}
healthy() { curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$1$2"; }

while [ $# -gt 0 ]; do
  port="$1" path="$2"; shift 2
  old="$(roots "$port" | tr '\n' ' ')"
  if [ -z "${old// /}" ]; then
    echo "port $port: nothing listening (first deploy? create the Ploi daemon); not waiting"
    continue
  fi
  echo "port $port: $sig to $old"
  # shellcheck disable=SC2086 # one or more PIDs
  kill -s "$sig" $old
  end=$(( $(date +%s) + timeout ))
  until now="$(roots "$port" | tr '\n' ' ')"; [ -n "${now// /}" ] && [ "$now" != "$old" ] && healthy "$port" "$path"; do
    [ "$(date +%s)" -lt "$end" ] || die "port $port: no healthy new process after ${timeout}s (supervisorctl status; the daemon's log in Ploi)"
    sleep 1
  done
  echo "port $port: healthy ($now)"
done
