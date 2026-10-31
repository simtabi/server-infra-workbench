# Releasing

The repository follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and keeps a
[changelog](../CHANGELOG.md) in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## What is versioned

| Part | Version lives in | Bump when |
|---|---|---|
| The repository (tags `vX.Y.Z`) | `CHANGELOG.md` headings | any release |
| DB server manager | `VERSION=` in `shell/db/docker-db-server-manager.sh` (`--version`) | its behaviour or generated files change |
| PHP library and CLI | `ClientOptions::VERSION` in `php/src/Http/ClientOptions.php` (`bin/workbench version`) | its public API or CLI changes |
| Python package | `version` in `python/pyproject.toml` and `__version__` | its CLI or API changes |

**Major**: a removed command, flag, class or method; a changed default that alters what runs on a server;
removing the `scripts/` shims. **Minor**: new commands, flags, platforms or options, backwards compatible.
**Patch**: fixes and docs. Until 1.0.0 the PHP and Python packages may make breaking changes in a minor
release, called out under **Changed** in the changelog.

## Checklist

1. `git status` is clean and you are on `main`.
2. `make ci` is green locally; for DB manager changes, `make it` too (Docker, about 3 minutes).
3. Bump the versions that changed (table above).
4. In `CHANGELOG.md`, rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD` and start a new empty `[Unreleased]`.
5. Docs: every new flag or command is in its `docs/tools/` page and, if user-facing, the README.
6. Commit: `git commit -am "Release X.Y.Z"`, then tag: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
7. Push the commit and the tag when a remote exists: `git push && git push --tags`.
8. Roll out to servers deliberately; for the manager use
   [roll-out-a-manager-upgrade](recipes/roll-out-a-manager-upgrade.md), never `reset` on a server with data.

## Hotfix

Branch from the tag (`git switch -c hotfix/X.Y.Z+1 vX.Y.Z`), fix, add a test, follow the checklist with a
patch bump, and merge back into `main`.
