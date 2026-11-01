# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (after the new release is live), as ploi.
# preload_app! means a phased restart can't load new code, so restart Puma: TERM finishes in-flight requests
# (and lets Solid Queue finish or release its jobs), Supervisor starts it on the new release, /up is Rails 8's
# built-in health check.
/usr/local/bin/siw-reload-daemon --timeout 90 3000 /up
