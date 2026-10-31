# 0004. Every write is a pending action that must be confirmed

- Status: Accepted
- Date: 2026-10-31

## Context

The clients act on production infrastructure. A fluent call such as `->snapshot($id)` or
`->dns($zone)->delete($id)` is easy to run by accident in a REPL or a script, and the CLI must offer a
dry run that shows exactly what would be sent.

## Decision

Reads execute immediately. Every write returns a `PendingAction` that holds the method, path and payload and
does nothing until `confirm()` is called (once). `plan()` returns the request without sending it. Deletes are
flagged destructive. Each dry run and write is appended to a JSONL audit log (no tokens, no payloads). The
CLI requires `--yes` (or typing `yes` at a prompt) for writes, and additionally `--force` for destructive
writes; `--dry-run` calls `plan()`.

## Consequences

Library calls are one step longer (`->confirm()`), in exchange for the same safety model in code and on the
command line and a trustworthy dry run. Operations that would need several requests (DNS upsert) do their
reads when the action is built, so the plan reflects the current state.
