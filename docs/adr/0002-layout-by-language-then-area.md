# 0002. Lay the repository out by language, then by area

- Status: Accepted, amended by [0006](0006-all-code-under-src-no-shims.md)
- Date: 2026-10-31

## Context

The original `scripts/` folder mixed tools that run on servers with workstation helpers, and there was no
place for code in other languages. Each language has its own tooling (shellcheck, Composer and PSR-4,
pyproject and the `src/` layout) that works best on a self-contained folder.

## Decision

Top-level folders by language or artefact type (`shell/`, `php/`, `python/`, `stacks/`, `config/`,
`docs/`), and inside `shell/` one folder per area (`db/`, `web/`, `deploy/`, `tunnels/`). One entry point,
`bin/workbench`, reaches all of them. Old `scripts/` paths keep working through shims until the next major
release. Docs follow the other Simtabi packages: guides in `docs/`, tool references in `docs/tools/`,
recipes in `docs/recipes/`.

## Consequences

Each language's tooling runs unmodified; new tools have an obvious home (see
[structure.md](../structure.md#where-new-things-go)). Paths changed once, so the shims and the old-to-new
table must stay until they are removed in a major release.
