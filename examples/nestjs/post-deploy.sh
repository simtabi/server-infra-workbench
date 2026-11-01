# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (after the new release is live), as ploi.
# enableShutdownHooks() drains on TERM; Supervisor starts dist/main.js from the new release.
/usr/local/bin/vsw-reload-daemon 3001 /health
