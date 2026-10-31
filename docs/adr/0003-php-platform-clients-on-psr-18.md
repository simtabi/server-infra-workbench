# 0003. Platform API clients in PHP on PSR-18, without vendor SDKs

- Status: Accepted
- Date: 2026-10-31

## Context

We need to automate DigitalOcean, Cloudflare, Ploi and Google Compute Engine (snapshots before upgrades,
DNS records, deploys, inventory). Official SDKs exist for some of them but differ widely in style, pull large
dependency trees (the Google Cloud PHP SDK alone is very large), and do not share retries, redaction or a
safety model. The team writes PHP daily; shell is poor at JSON, pagination and error handling.

## Decision

Write small typed clients in PHP 8.4 over one shared transport built on PSR-18 (client), PSR-17
(factories) and PSR-3 (logging), with Guzzle as the default implementation. Only the endpoints we use are
covered; DTOs and enums are immutable. Python stays a small helper package and does not get a second copy of
these clients. Quality gates: Pint, PHPStan at level max with strict rules, PHPUnit with a mock client.

## Consequences

One retry, rate-limit, pagination, redaction and audit implementation for all platforms; few dependencies;
any PSR-18 client can be swapped in. We maintain the endpoint mappings ourselves and add endpoints as needed.
GCP support is deliberately minimal (service-account JWT or gcloud, Compute Engine only).
