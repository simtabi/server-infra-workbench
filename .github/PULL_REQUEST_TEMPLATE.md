## What does this change?

<!-- One or two sentences. Link the issue if there is one. -->

## Why?

<!-- The problem this solves. For server-side changes, say what happens on a live server. -->

## Checklist

- [ ] `make ci` passes (and `make it` for DB manager changes)
- [ ] Tests added or updated; no test touches the network or a real server
- [ ] No secrets, real tokens or project names outside `examples/` and `CHANGELOG.md`
- [ ] New writes are safe by default (`--dry-run`, confirmation, `PendingAction`; destructive flagged)
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` (user-facing changes)
- [ ] Docs updated (`docs/tools/`, recipes, README)
