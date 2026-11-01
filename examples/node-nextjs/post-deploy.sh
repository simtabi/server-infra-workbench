# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (after the new release is live), as ploi.
# server.js handles SIGTERM (finishes open requests); Supervisor starts it from the new release.
/usr/local/bin/siw-reload-daemon 3000 /api/health
