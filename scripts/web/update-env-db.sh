#!/usr/bin/env bash
# Compatibility shim: this script moved to shell/web/update-env-db.sh (vps-server-workbench layout,
# see docs/structure.md#old-to-new-paths). Behaviour is unchanged; update your
# commands to the new path. This shim will be removed in a future major release.
echo "note: scripts/web/update-env-db.sh moved to shell/web/update-env-db.sh" >&2
exec "$(cd "$(dirname "$0")/../.." && pwd)/shell/web/update-env-db.sh" "$@"
