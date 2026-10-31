#!/usr/bin/env bash
# Compatibility shim: this script moved to shell/db/remote-run.sh (vps-server-workbench layout,
# see docs/structure.md#old-to-new-paths). Behaviour is unchanged; update your
# commands to the new path. This shim will be removed in a future major release.
echo "note: scripts/db/remote-run.sh moved to shell/db/remote-run.sh" >&2
exec "$(cd "$(dirname "$0")/../.." && pwd)/shell/db/remote-run.sh" "$@"
