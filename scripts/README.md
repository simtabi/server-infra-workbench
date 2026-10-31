# scripts/ (compatibility shims)

The shell scripts moved to [`shell/`](../shell) when the project became `vps-server-workbench`.
Each file here only prints a one-line note and `exec`s the new path with the same arguments, so old
commands keep working. Use the new paths; these shims will be removed in a future major release.
Mapping: [docs/structure.md](../docs/structure.md#old-to-new-paths).

Not shimmed: `scripts/deploy/ploi-deploy.sh` (it is pasted into Ploi, so use `shell/deploy/ploi-deploy.sh`), and
piping the manager over ssh (`bash -s < ...`) must use `shell/db/docker-db-server-manager.sh`, because a shim
cannot run on the server.
