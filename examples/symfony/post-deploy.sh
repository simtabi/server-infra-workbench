# shellcheck shell=bash
# Ploi -> Site -> Deploy script -> post-deploy section (after the new release is live), as ploi.
#
# 1. FIRST LINE in Ploi: the {RELOAD_PHP_FPM} placeholder on a line of its own (Ploi swaps in the reload
#    command for the site's PHP version). OPcache still holds the old release's files until FPM reloads.
#    It is not written out here because the placeholder is not valid shell until Ploi replaces it.
#
# 2. Messenger workers finish their current message and exit; Supervisor starts them on the new release.
cd /home/ploi/shop.example.com && php bin/console messenger:stop-workers
