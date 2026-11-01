# GitHub (`siwo github`, alias `gh`)

**Why:** deploys are driven from GitHub: Actions runs build and test, secrets hold deploy credentials, deploy
keys let a server pull its repository, and releases tag what went out. The workbench uses the REST API
(`https://api.github.com`, `X-GitHub-Api-Version` pinned) so a rollout can set a secret, add a read-only deploy
key, dispatch a workflow and watch it finish, with the same plan/confirm/audit as every other provider. The
`gh` CLI is not required (and the alias name does not clash with it: this one is `bin/siwo gh`).

## Least-privilege token

Use a **fine-grained personal access token** (Settings → Developer settings → Fine-grained tokens) limited to the
repositories you manage, with an expiry. Store it as `GITHUB_TOKEN`.

| Commands | Repository permission |
| --- | --- |
| `whoami`, `rate-limit`, `repos`, `repo` (and the live test) | Metadata: Read (always included) |
| `workflows`, `runs`, `run` | Actions: Read |
| `dispatch`, `rerun`, `cancel` | Actions: Read and write |
| `secrets list` / `set`, `delete` | Secrets: Read / Read and write (environment secrets: Environments: Read and write) |
| `deploy-keys list` / `add`, `delete` | Administration: Read / Read and write |
| `releases list/latest` / `create`, `delete` | Contents: Read / Read and write |

The live read-only test needs Metadata, Contents and Actions read. For `repos --org O` the token's resource
owner must be that organisation (or the org must allow fine-grained tokens).

## Commands

`--repo owner/name` names the repository. All take `--json`; writes take `--dry-run`, `--yes`; destructive
writes need `--force`.

- `bin/siwo github whoami`, `bin/siwo github rate-limit`
- `bin/siwo github repos --org <org> --limit 100`, `bin/siwo github repo --repo owner/name`
- `bin/siwo github workflows --repo owner/name`
- `bin/siwo github runs --repo owner/name --workflow ci.yml --branch main --status failure --limit 20`
- `bin/siwo github run <run-id> --repo owner/name --wait --timeout 1800` polls until the run completes
  (or the timeout passes) and shows its result.
- `bin/siwo github dispatch ci.yml --repo owner/name --ref main --inputs target=staging`
- `bin/siwo github rerun <run-id> --repo owner/name` re-queues the failed jobs; `bin/siwo github cancel <run-id> --repo owner/name`
- `bin/siwo github secrets list --repo owner/name --env production`
- `bin/siwo github secrets set DEPLOY_KEY --repo owner/name --env production --value-file ~/.config/server-infra-workbench/deploy.key`
  (or the value on stdin). The value is sealed locally with the repository's public key (libsodium sealed box)
  and sent encrypted; it is never accepted on the command line and never printed or logged.
- `bin/siwo github secrets delete DEPLOY_KEY --repo owner/name --force`
- `bin/siwo github deploy-keys list --repo owner/name`
- `bin/siwo github deploy-keys add --repo owner/name --title "app server" --key-file ~/.ssh/app_deploy.pub`
  adds a read-only key; `--write` (push access) also needs `--force`.
- `bin/siwo github deploy-keys delete <key-id> --repo owner/name --force`
- `bin/siwo github releases list --repo owner/name`, `bin/siwo github releases latest --repo owner/name`
- `bin/siwo github releases create v1.4.0 --repo owner/name --target main --title "v1.4.0" --notes-file CHANGELOG.md --draft`
- `bin/siwo github releases delete <release-id> --repo owner/name --force`

The PHP `sodium` extension is needed for `secrets set` (bundled with most PHP 8.4 builds; `php -m | grep sodium`).

## Checklist

- [ ] Fine-grained token, selected repositories only, with an expiry; no classic `repo` scope token.
- [ ] Deploy keys are read-only, one per server, titled with the server name.
- [ ] Secrets go in from a file or stdin, never `echo VALUE |` in shell history; prefer environment secrets with
      required reviewers for production.
- [ ] `bin/siwo github runs --repo owner/name --status failure` is empty before a release.

## Lessons learned

- **Secrets come only from a file or stdin.** A value on the command line lands in shell history and `ps`; the
  CLI has no flag for it, refuses an empty value and anything over GitHub's 48 KB limit, and validates the
  name (no `GITHUB_` prefix, letters, digits and underscores).
- **The seal happens at confirm.** The plan shows the secret name only; the repository public key is fetched and
  the value encrypted when you confirm, so a dry run never touches the secret.
- **Exhausted quota is a 403, not a 429.** GitHub reports the primary limit as 403 with
  `x-ratelimit-remaining: 0`; the transport waits for `x-ratelimit-reset` (bounded) and retries instead of
  failing as "forbidden".
- **Write deploy keys are push credentials.** A server that only pulls needs a read-only key, so `--write` is
  treated as destructive.
- **Dispatch is fire-and-forget.** The API answers 204 without a run id; follow up with
  `bin/siwo github runs --repo owner/name --workflow ci.yml --limit 1`.
