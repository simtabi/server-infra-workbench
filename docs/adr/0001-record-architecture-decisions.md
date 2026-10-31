# 0001. Record architecture decisions

- Status: Accepted
- Date: 2026-10-31

## Context

The repository grew from a few shell scripts into shell tools, a PHP library, a Python package and Docker
stacks. Several choices (layout, safety model, credential handling) are not obvious from the code alone.

## Decision

Record significant decisions as numbered Markdown files in `docs/adr/`, using context, decision and
consequences. Records are immutable once accepted; a later record may supersede an earlier one.

## Consequences

New contributors can see why things are the way they are. A decision that needs an ADR is also a signal to
discuss it in the pull request.
