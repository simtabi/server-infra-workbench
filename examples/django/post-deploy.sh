# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> "post-deploy" section (runs after the new release is live), as ploi.
# Gunicorn keeps running the release it started in, so restart it: TERM lets workers finish their requests,
# Supervisor starts it again from the new release, and the script waits for /healthz from the new process.
/usr/local/bin/siw-reload-daemon 8000 /healthz
# two daemons (PORT=8000 and PORT=8001, nginx-site.conf upstream): restart one at a time, no gap
#/usr/local/bin/siw-reload-daemon 8000 /healthz 8001 /healthz
