# Contributing

Thanks for helping improve `simtabi/vps-server-workbench`. Please read the
[Code of Conduct](CODE_OF_CONDUCT.md) first, and report security issues as described in
[SECURITY.md](SECURITY.md), not in public issues.

## Getting set up

```bash
composer install --working-dir=src/php       # PHP 8.4+, for the platform APIs
make help                                # every target
make ci                                  # the gate CI runs
```

Tools: bash 4+, shellcheck, python3 (3.12+ for the Python package), PHP 8.4+ with Composer, docker for the
compose checks. Optional: shfmt (`make fmt-check`), ruff, [pre-commit](https://pre-commit.com)
(`pre-commit install` uses [.pre-commit-config.yaml](.pre-commit-config.yaml)). Missing PHP, Python or
docker makes the matching `make` targets skip with a note.

Where things go and how to name them: [docs/structure.md](docs/structure.md#where-new-things-go).

## What must pass

- **Shell**: `make lint` (`bash -n` and shellcheck on every `*.sh`, settings in `.shellcheckrc`) and
  `make test` (offline smoke tests). For DB manager changes also `make it` (Docker, about 3 minutes).
- **PHP**: `make php`: Pint (`--test`), PHPStan at level max with strict rules and no baseline, PHPUnit.
- **Python**: `make python`.
- **Docs**: `make links` (relative links and anchors).

## Rules

- **No secrets**, ever: not in code, tests, examples, docs or commit messages. Use obvious placeholders
  (`<token>`, `203.0.113.10`, `example.com`).
- **No project names outside `examples/` and `CHANGELOG.md`**; `make test` enforces it.
- **Tests never touch the network or a real server.** PHP tests use the mock PSR-18 client in
  `src/php/tests/Fixtures`; shell tests stub `docker`/`ssh`.
- **Safe by default**: new platform writes return a `PendingAction` (destructive ones flagged), and new
  server commands support `--dry-run` and refuse to run on the wrong host. See [docs/adr](docs/adr/README.md).
- **Pinned versions** for images and dependencies; prefer the newest stable release.
- Do not change a script's behaviour in a docs or refactor commit.

## Pull requests

- Tests added or updated; `make ci` passes.
- `CHANGELOG.md` updated under `## [Unreleased]` for user-facing changes.
- Docs updated: the tool's page in `docs/tools/`, recipes that use it, and the README if it is user-facing.
- One logical change per commit, with a message that says what and why.
- Version bumps follow [docs/release.md](docs/release.md).
