# 0005. Credentials come from the environment or a private file outside the repo

- Status: Accepted
- Date: 2026-10-31

## Context

API tokens grant control of servers, DNS and deploys. Tokens in `.env` files inside a working tree are easy
to commit by mistake, and tokens in logs or exception messages leak through CI output and bug reports.

## Decision

Credentials are resolved from an explicit value, then the environment, then
`~/.config/server-infra-workbench/credentials` (or `$SIW_CREDENTIALS_FILE`). The file is refused unless it is
mode 600, owned by the current user and not inside a git working tree; service-account key files get the
same checks. Tokens are wrapped in a `Secret` type that prints as `***` and refuses serialization, and every
log line and error message passes through a redactor. `bin/workbench credentials` reports where each value
comes from, never the value.

## Consequences

No secrets in the repository by construction; the smoke tests also scan tracked files for generated
passwords. Users must create the file with the right permissions once (see
[configuration](../configuration.md#platform-credentials)).
