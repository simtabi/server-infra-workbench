# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security report. Two channels, in order of preference:

1. **GitHub private vulnerability reporting**, from this repository's Security tab, once the repository is
   published there.
2. **Email `security@simtabi.com`**.

Include a description of the issue, the affected version or commit, and steps to reproduce. Never include
real tokens, passwords or private keys; redact them.

You will receive an acknowledgement within three working days. We aim to ship a fix, or a documented
mitigation, within 30 days of confirming the report, and will credit you in the changelog unless you ask
otherwise.

## Scope

In scope: anything in this repository, including scripts that run as root on servers (the DB manager), the
deploy script, the Caddy stack, the PHP clients and CLI (credential handling, redaction, request building)
and the docs' recommended commands. Out of scope: vulnerabilities in DigitalOcean, Cloudflare, Ploi, Google
Cloud or upstream images; report those to the vendor.

## Supported versions

Only the latest commit on `main` (and the latest tag, once tags exist) receives security fixes.

## How this repository handles secrets

- No secrets are committed: credentials come from environment variables or a chmod 600 file outside any git
  tree (see [docs/configuration.md](docs/configuration.md#platform-credentials)); `make test` scans tracked files.
- Tokens are wrapped in a type that never prints, and all logs and errors are redacted.
- Database passwords are generated on the DB server and stay in root-only files there.

If you find a secret in the history, report it as a vulnerability so it can be rotated.
