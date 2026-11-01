# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (runs after the new release is live), as ploi.
# Put Ploi's {RELOAD_PHP_FPM} placeholder on the first line (OPcache), then:
set -euo pipefail
cd /home/ploi/app.example.com
php artisan horizon:terminate   # finishes the running jobs, exits; Supervisor starts Horizon on the new release
php artisan reverb:restart      # closes connections cleanly; clients reconnect to the restarted daemon
