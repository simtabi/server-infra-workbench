# Providers

`bin/siwo` talks to five platforms over their public REST APIs, with no vendor SDKs and no CLIs required.
Each page explains why the area exists, the least-privilege token, every command, a checklist and the lessons
that shaped the defaults.

| Provider | Page | CLI area | Credential |
| --- | --- | --- | --- |
| DigitalOcean | [digitalocean.md](digitalocean.md) | `do` | `DIGITALOCEAN_TOKEN` |
| Cloudflare | [cloudflare.md](cloudflare.md) | `cf` | `CLOUDFLARE_API_TOKEN` |
| Google Cloud | [gcp.md](gcp.md) | `gcp` | `GOOGLE_APPLICATION_CREDENTIALS` + `GCP_PROJECT` |
| GitHub | [github.md](github.md) | `github` (alias `gh`) | `GITHUB_TOKEN` |
| Ploi | [ploi.md](ploi.md) | `ploi` | `PLOI_API_TOKEN` |

## Shared behaviour (all providers)

One HTTP core (`Http\Transport`) is shared by every client, so these hold everywhere:

- **HTTPS only.** Any non-`https://` base URL or pagination link is refused before a request carrying the token
  is built.
- **Retries with backoff and jitter** on 429 always, and on 500/502/503/504 and network errors only for idempotent
  methods (a POST is never sent twice). `Retry-After` wins over the backoff. GitHub's secondary limit (403 with `x-ratelimit-remaining: 0`) is treated as a 429 and waits for
  the reset.
- **Pagination** is followed for you: page/per_page (DigitalOcean, Cloudflare, Ploi), `nextPageToken` (GCP) and
  `Link: rel="next"` (GitHub).
- **Timeouts** on connect and on the whole request; long operations (droplet resize, snapshots, GCP operations,
  workflow runs) poll with `--wait` / `--timeout`.
- **Redirects are refused** rather than followed with the credentials attached.
- **Typed errors** (all `WorkbenchException`): `AuthenticationException` (401/403), `NotFoundException` (404),
  `ApiValidationException` (400/422), `RateLimitException` (429 after the retries), `ApiException` (other HTTP
  errors), `TransportException` (network), `TimeoutException` (waits), `ValidationException` (refused locally,
  before any request), `CredentialException` (missing token). The CLI maps them to exit codes: 0 ok, 1 failed, 2 usage, 3 not confirmed,
  4 credentials.
- **Redacted logs.** `--verbose` logs method, path and status to stderr; `Authorization`, tokens, passwords,
  private keys and secret values are replaced with `***`. The audit log records every write and dry run.
- **Writes are pending actions.** Nothing is sent until you confirm: `--dry-run` prints the plan (sensitive
  fields as `***`), `--yes` skips the prompt, and destructive writes also need `--force`. Writes are idempotent
  where the API allows (create-by-name, upsert, no-op when nothing changes).
- **One-time secrets** (Spaces secret keys, Origin CA private keys, generated database passwords) go to a file
  given with `--out`, created with mode 600, never printed and never inside the git checkout. The path is
  checked before any request is made.

Credentials come from the environment or `~/.config/server-infra-workbench/credentials` (mode 600); see
[`config/credentials.env.example`](../../config/credentials.env.example) and `bin/siwo credentials`, which
reports which are set without printing them.

## Tests

- Unit and contract tests (`make php`) use a mocked HTTP client: pagination, retries, `Retry-After`, error
  mapping, plans and redaction. No network, no real or credential-shaped values.
- Live read-only tests (`src/php/tests/Live`) run only with `SIWO_LIVE=1` and the provider's token, and go
  through a client that refuses anything but GET (plus the Google OAuth token exchange):

```bash
cd src/php && SIWO_LIVE=1 vendor/bin/phpunit --testsuite live           # skips any provider without a token
```
