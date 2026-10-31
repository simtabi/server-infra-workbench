# Architecture decision records

Short records of decisions that shape the repository, in the
[Michael Nygard format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
(context, decision, consequences). Add one when a choice would surprise a new contributor or is costly to
reverse. Number them in order; never rewrite an accepted record, supersede it with a new one.

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-layout-by-language-then-area.md) | Lay the repository out by language, then by area | Amended by 0006 |
| [0003](0003-php-platform-clients-on-psr-18.md) | Platform API clients in PHP on PSR-18, without vendor SDKs | Accepted |
| [0004](0004-writes-are-pending-actions.md) | Every write is a pending action that must be confirmed | Accepted |
| [0005](0005-credentials-outside-the-repo.md) | Credentials come from the environment or a private file outside the repo | Accepted |
| [0006](0006-all-code-under-src-no-shims.md) | All code under src/, no compatibility shims | Accepted |
