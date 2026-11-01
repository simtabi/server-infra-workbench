# 0014. Rename to server-infra-workbench and `siwo`; frozen on-server identifiers; time-boxed fallbacks

- Status: Accepted
- Date: 2026-11-01

## Context

The project started as droplet tooling and was named `vps-server-workbench`. It now manages much more than
one VPS: platform APIs for DigitalOcean, Cloudflare, Google Cloud, GitHub and Ploi, a database server
manager, add-on stacks (object storage, search, mail), monitoring, WireGuard between regions, deploy
presets, and live tests against real cloud accounts. "VPS" undersold that and suggested a single
provider's product. The new name says what it is: a workbench for server infrastructure.

A rename touches three kinds of names, and they do not cost the same to change:

1. **Names in this repository** (GitHub repo, folder, Composer package, PHP namespace, Python package,
   docs, badges). Free to change: GitHub redirects the old URL, and nothing outside the repo imports the
   namespace.
2. **Names a person sets on their workstation**: the `VSW_*` environment variables and the
   `~/.config/vps-server-workbench/` credentials and `keys.json`. Changing these silently would make a
   working setup fail (no token found, wrong image) after a `git pull`.
3. **Names on servers that already run the tools**: the `vsw_admin` / `vsw_monitor` database roles,
   `vsw_*` Prometheus metrics and dashboards, `/opt/vsw-monitor`, `/opt/vsw-addons`,
   `/etc/vsw-*.conf`, the `vsw_db` Docker network, `vsw-*` containers and compose projects,
   `/etc/cron.d/vsw-inventory`, `/run/lock/vsw-*.lock`, and the `/etc|/var/lib|/var/log/vps-server-workbench`
   directories. Renaming these is a migration on every live server (role renames, metric series
   restarting, alert history lost, containers recreated), which is risky and has no benefit for the user.

ADR [0006](0006-all-code-under-src-no-shims.md) says "no compatibility shims". That was about code paths in
an unpublished tree. Settings and on-disk state are different: they belong to the people and servers
using the tool, and breaking them is not ours to decide.

## Decision

- **Repository names change everywhere**: `simtabi/server-infra-workbench` (GitHub, folder, Composer
  package), `Simtabi\ServerInfraWorkbench` (PHP), `server_infra_workbench` (Python). `sshmgr` is a separate
  project and is not renamed.
- **The command is `siwo`** (Server + Infrastructure + WOrkbench): `bin/siwo`, `siwo-py`, `src/php/bin/siwo-php`.
  `workbench` was a generic word that collides with other tools on a `PATH` and reads as prose in the docs
  ("the workbench"); `siwo` is short, unique, and names the project. `bin/workbench` stays as a thin shim that
  prints one deprecation notice (hidden by `SIWO_QUIET=1`) and execs `bin/siwo`, so scripts, shell aliases
  and runbooks keep working; `workbench-py` stays as a second console-script name. The docs checker
  (`tests/docs/check-commands.py`) treats `siwo` as canonical and fails on `bin/workbench` outside the
  CHANGELOG, this ADR and the two pages that explain the shim. `remote-run.sh --snapshot-with` takes `siwo`
  and still accepts `workbench`.
- **Settings are `SIWO_*`**, the command's name, so a variable says which tool reads it. An unset `SIWO_X` falls back to `VSW_X`, and each `VSW_*` that is set prints one
  `note: VSW_X is deprecated, use SIWO_X` line on stderr (shell: `lib/progress.sh`, embedded in the DB
  manager; PHP: `Support\Env`; Python: `compat`). The notice is printed once per name per process tree.
- **Per-user paths** are `~/.config/server-infra-workbench/` and `~/.local/state/server-infra-workbench/`.
  While only the old `vps-server-workbench` directory has the file, the old one is used (`Env::userPath`),
  so nobody has to move a credentials file.
- **On-server long-name directories** (`/etc`, `/var/lib`, `/var/log`, `/usr/local/lib`) are
  `server-infra-workbench` on new servers; `siw_path` keeps using an existing `vps-server-workbench`
  directory while the new one does not exist.
- **Short `vsw` identifiers on servers are frozen** (the list in Context, item 3). They are opaque
  prefixes, documented in [naming](../reference/naming.md#frozen-identifiers), not the product name.
- **Temporary names** (`/tmp/siw-*`, `mktemp` templates) and **live-test names** (`siw-livetest` tag,
  `siwlt-` prefix) use the new prefix. `tests/live/sweep.sh` also sweeps the old `vsw-livetest` /
  `vswlt-` names. Integration-test containers keep the `vsw` prefix because the code under test creates
  `vsw-*` objects and the leak guard must see both. Lowercase `siw` (the project's initials) stays in these
  throwaway resource names; `siwo` is for the command and its settings.
- Labels and descriptions already written to cloud resources (`managed-by: workbench` on GCE, `managed by
  workbench` on Cloud DNS and firewalls, `workbench: ...` on DO alert policies, the `X-Client: workbench`
  header) are unchanged: existing resources carry them and filters match on them.
- The fallbacks (`VSW_*`, old directories, `bin/workbench`, `workbench-py`) are removed in the first release after 1.0 that is allowed to break settings, with a
  CHANGELOG entry; until then they are tested (`smoke-progress`, `EnvTest`, `test_compat`).

## Consequences

- A `git pull` changes nothing for a working setup: old variables and paths still work and say what to
  rename. The GitHub redirect keeps old clone URLs, issue links and badges working, but a new
  repository named `vps-server-workbench` under the same owner would break the redirect, so that name is
  never reused.
- Servers already running the tools keep their roles, metrics, dashboards and directories. Files the tools
  manage with a `# Managed by ...` header get the new header on their next re-run (a header-only change,
  backed up like any other).
- Mixed names stay visible on servers (`vsw_admin` next to `server-infra-workbench`). That is the cost of
  not migrating live servers; the naming reference explains it.
