# 0006. All code under src/, no compatibility shims

- Status: Accepted (amends [0002](0002-layout-by-language-then-area.md))
- Date: 2026-10-31

## Context

ADR 0002 put each language at the top level (`shell/`, `php/`, `python/`) next to `tools/` and a
`scripts/` folder of shims for the old paths. With nine top-level folders the tree looked cluttered and it
was not obvious where code ends and docs, config or examples begin. The repository had never been
published, so nobody depends on the old paths.

## Decision

- All code lives under `src/`: `src/shell/<area>/`, `src/php/`, `src/python/`. The top level is only
  `bin/ src/ stacks/ config/ docs/ examples/ tests/` plus the root files.
- Standalone helpers become subcommands of a package (the plan finder is `bin/workbench plans`), not a
  `tools/` folder.
- `scripts/` and every shim are deleted. Moves before 1.0 are listed in
  [structure.md](../structure.md#old-to-new-paths) instead.
- Every top-level folder has a short `README.md`.

## Consequences

- The tree answers "where is X" at a glance; `bin/workbench list` answers it from the terminal.
- Anyone with a pre-release checkout must use the new paths; the live server paths are unchanged.
- Package tooling runs with `--working-dir=src/php` and `PYTHONPATH=src/python/src`.
