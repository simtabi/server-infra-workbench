# 0009. MongoDB is not managed by the DB manager

- Status: Accepted
- Date: 2026-10-31

## Context

The environment design asked whether MongoDB should get the same layout as Postgres, MySQL and MariaDB.
Runtime tenant databases need a role that can create databases but only with an env's prefix. MongoDB roles
are per database or cluster-wide: creating databases at runtime needs `readWriteAnyDatabase` (or an admin
creating a role per database), which breaks environment isolation. A self-hosted replica set also adds an
always-on process and its own backup tooling for a feature the apps don't use. Postgres `jsonb` with GIN
indexes covers flexible documents.

## Decision

- The manager refuses `mongodb` as an engine (`env-init`, `create-db`) and points here.
- If an app genuinely needs MongoDB, use a managed service (MongoDB Atlas or DigitalOcean Managed MongoDB)
  with one database and one user per environment; connection notes are in
  [Connect to databases](../recipes/connect-to-databases.md#10-mongodb-not-needed).

## Consequences

- No Mongo containers, backups or doctor checks to maintain.
- Teams that want Mongo pay for a managed service and handle its tenancy in the app.
