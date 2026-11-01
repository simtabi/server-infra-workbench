# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (after the new release is live), as ploi.
# TERM: Uvicorn's manager stops taking connections, lets workers finish, exits; Supervisor starts it on the
# new release; this waits for /healthz (which also checks the DB pool) from the new process.
/usr/local/bin/vsw-reload-daemon 8000 /healthz
