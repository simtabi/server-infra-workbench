# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (after the new release is live), as ploi.
# TERM: the API drains (srv.Shutdown), systemd (Restart=always) starts the new release's binary within 1 s.
# No sudo needed: the process belongs to ploi.
/usr/local/bin/siw-reload-daemon 8080 /healthz
