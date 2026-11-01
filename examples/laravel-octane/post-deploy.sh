# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (runs after the new release is live), as ploi.
# Not `octane:reload`: that restarts the workers of the running server, which resolved its release directory
# when it started, so it would reload the OLD release. TERM the server instead; Supervisor starts
# `octane:start` again from the new release and this waits for /up from the new process. ~1-3 s of 502s
# (Nginx retries once, nginx-site.conf); two daemons on two ports remove the gap (django example).
/usr/local/bin/vsw-reload-daemon --timeout 90 8000 /up
