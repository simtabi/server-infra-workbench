# Platform API library (`php/`)

Typed, fluent PHP clients for **DigitalOcean**, **Cloudflare**, **Ploi**, **Google Cloud** (Compute Engine, Cloud
DNS, Cloud Storage) and **GitHub**, sharing one HTTP core. Per-provider guides (token scopes, every command,
checklists, lessons learned) are in [docs/providers](../providers/README.md). The [`bin/workbench` CLI](cli.md) is a thin layer over this library; you can also use it from any
PHP 8.4+ project or script.

- **Namespace** `Simtabi\ServerInfraWorkbench\` (PSR-4, `src/php/src/`), package `simtabi/server-infra-workbench`.
- **Standards** PSR-18 HTTP client and PSR-17 factories (Guzzle by default; inject any client), PSR-3 logger,
  PSR-12/PER style enforced by Pint, PHPStan level `max` with strict rules.
- **No vendor SDKs.** Each platform is a few small classes over the same `Transport` (see
  [ADR 0003](../adr/0003-php-platform-clients-on-psr-18.md)).
- **Read-only by default.** Every write returns a `PendingAction`; nothing is sent until you call `confirm()`
  ([ADR 0004](../adr/0004-writes-are-pending-actions.md)).

## Install

```bash
composer install --working-dir=src/php          # from the repo root; locked versions, PHP 8.4+
make php                                    # pint --test, phpstan, phpunit
```

In another project, add this repo as a Composer `path` (or `vcs`) repository and
`composer require simtabi/server-infra-workbench`.

## Quick start

```php
use Simtabi\ServerInfraWorkbench\DigitalOcean\DigitalOcean;

$do = DigitalOcean::make();                                  // token from DIGITALOCEAN_TOKEN or the credentials file

foreach ($do->droplets()->list(tag: 'db') as $droplet) {
    echo $droplet->name, ' ', $droplet->status->value, ' ', $droplet->privateIpv4, PHP_EOL;
}

$snapshot = $do->droplets()->snapshot(123456, 'db-pre-upgrade');   // PendingAction - nothing sent yet
print_r($snapshot->plan());                                          // dry run: method, path, payload (audited as dry-run)
$action = $snapshot->confirm()->wait(timeoutSeconds: 1800);          // send, then poll until completed/errored
```

```php
use Simtabi\ServerInfraWorkbench\Cloudflare\Cloudflare;

$dns = Cloudflare::make()->dns('example.com');               // zone by name or 32-char id
$dns->upsert('A', 'db', '203.0.113.10', ttl: 300)->confirm(); // create, update or no-op; refuses duplicates
$dns->list(type: 'CNAME');
$dns->delete($recordId)->confirm();                           // destructive: PendingAction::isDestructive() === true
```

```php
use Simtabi\ServerInfraWorkbench\Ploi\Ploi;

$server = Ploi::make()->servers()->find(42);                  // lazy, scoped handle; no request yet
$server->get();                                               // Server DTO
$server->sites()->list();
$server->sites()->deploy(1001)->confirm();
```

```php
use Simtabi\ServerInfraWorkbench\Gcp\Gcp;

$gcp = Gcp::make('my-project');                               // service-account key or gcloud, see Credentials
$gcp->instances()->list();                                    // all zones (aggregated)
foreach ($gcp->firewalls()->list() as $rule) {
    if ($rule->isOpenToWorld()) { echo "open to 0.0.0.0/0: {$rule->name}\n"; }
}
$gcp->snapshots()->create('us-east1-b', 'db-disk', 'db-pre-upgrade')->confirm()->wait();
```

```php
use Simtabi\ServerInfraWorkbench\Github\Github;
use Simtabi\ServerInfraWorkbench\Security\Secret;

$repo = Github::make()->repo('owner/name');                    // token from GITHUB_TOKEN
$repo->workflows()->runs(workflow: 'ci.yml', branch: 'main');
$repo->secrets('production')->set('DEPLOY_KEY', new Secret($value))->confirm();   // sealed with libsodium at confirm
```

## API surface

| Entry point | Reads | Writes (return `PendingAction`) |
|---|---|---|
| `DigitalOcean::make($token?)` | `droplets()->list(?tag)`, `->find(id)`, `->snapshots(id)`, `snapshots()`, `actions()`, `account()`, `catalog()` (regions, sizes, images), `monitoring()`, `uptime()`, `firewalls()`, `volumes()`, `vpcs()` (incl. `members(id)`, `defaultFor(region)`), `spacesKeys()`, `domains()` / `domains()->records(domain)`, `reservedIps()`, `projects()`, `tags()` | droplet create/power/resize (**destructive** with `disk`)/snapshot/delete; `monitoring()->apply(Monitoring::standard(...))` (only missing policies); firewalls and uptime checks; volume create/attach/detach/grow (**destructive**; never shrinks)/delete; VPC create/`setDefault`/delete (refuses the default VPC or one with members); `spacesKeys()->create()` → `IssuedCredential` (the secret once); DNS `upsert` (no-op when it matches); reserved IP create/assign/unassign/delete; project `assign`; tag create/attach/detach/delete |
| `Cloudflare::make($token?)` | `zones()->list(?name)`, `->find(zone)`, `dns(zone)->list(?type, ?name)`, `zones()->settings(zone)->all()`, `->originCertificates(zone)->list()`, `->firewall(zone)->accessRules()`, `->firewall(zone)->customRules()`, `verifyToken()` | DNS `upsert`/`delete`; `settings(zone)->set(name, value)` (**destructive** when it weakens security; no-op when unchanged); `originCertificates(zone)->create(hostnames, days)` → `IssuedCredential` (key and CSR made locally); `->revoke(id)`; `cache(zone)->purgeFiles(urls)` / `->purgeEverything()` **destructive**; firewall access rule add/delete |
| `Ploi::make($token?)` | `servers()->list()`, `->find(id)->get()`, `->sites()->list()`, `->sites()->deployScript(id)`, `->daemons()`, `->crontabs()`, `->databases()`, `->certificates(siteId)` | site create/delete, `deploy(siteId)`, `setDeployScript()` (no-op if identical); daemon, cron, database (with a user → `IssuedCredential`, password generated locally) and certificate create/delete; `restart()` **destructive** |
| `Gcp::make($project?, $tokens?)` | `instances()->list(?zone)`, `->find(zone, name)`, `snapshots()->list()`, `firewalls()->list()`, `dns()->zones()`, `->records(zone)`, `storage()->list()`, `->find(bucket)`, `->objects(bucket)` | instance create/start/stop/reset/delete; `snapshots()->create(...)` → `RunningOperation`; firewall create (**destructive** when a non-web port is world-open)/delete; DNS zone create/delete and record `upsert`/`delete` (one atomic change); bucket create (private, versioned, optional delete-after-N-days lifecycle)/delete |
| `Github::make($token?)` | `user()`, `rateLimit()`, `repositories(?org)`, `repo(r)->get()`, `->workflows()->list()`, `->runs(...)`, `->run(id)`, `->wait(id)`, `->secrets(?env)->list()`, `->deployKeys()->list()`, `->releases()->list()`, `->latest()` | `workflows()->dispatch(workflow, ref, inputs)`, `->rerunFailed(id)`, `->cancel(id)`; `secrets(?env)->set(name, Secret)` (sealed box at confirm) / `->delete(name)`; `deployKeys()->add(title, key, readOnly)` (**destructive** when writable) / `->delete(id)`; `releases()->create(...)` / `->delete(id)` |

`IssuedCredential` holds a one-time secret (a Spaces secret key, an Origin CA private key, a generated database
password) next to the created item: `jsonSerialize()` returns only the item, and the CLI writes the secret to the
`--out` file (mode 600) and never prints it.

Lists follow pagination for you (DigitalOcean `links.pages.next`, Cloudflare `result_info`, Ploi `links.next`,
GCP `nextPageToken`, GitHub `Link: rel="next"`) and return typed, immutable DTOs (`Droplet`, `Snapshot`, `Action`, `AlertPolicy`, `Zone`, `DnsRecord`,
`Server`, `Site`, `Instance`, `Firewall`, `Operation`) with enums for statuses and record types. DTOs are `readonly` and
`JsonSerializable` (the CLI's `--json` output is exactly that).

## Pending actions (writes)

| Method | What it does |
|---|---|
| `describe()` | One line: provider, action, target, HTTP method and path, `[DESTRUCTIVE]` |
| `plan()` | The dry run. Returns method, path, payload and notes; sends nothing; writes a `dry-run` audit entry |
| `confirm()` | Sends the request once (a second call throws). Audit: `confirmed`, then `succeeded` or `failed` |
| `isDestructive()` | `true` for deletes. The CLI then also demands `--force` |
| `isNoop()` | `true` when there is nothing to do (for example a DNS upsert whose record already matches) |

## Options

`ClientOptions` is immutable; each `with*()` returns a copy. Pass it as the second argument of `make()`.

```php
use Simtabi\ServerInfraWorkbench\Http\{ClientOptions, RetryPolicy};
use Simtabi\ServerInfraWorkbench\Safety\JsonlAuditLog;

$options = ClientOptions::defaults()
    ->withTimeout(30, connectSeconds: 5)
    ->withRetry(RetryPolicy::default()->withMaxAttempts(6)->withBackoff(500, 20_000))
    ->withLogger($psr3Logger)                       // wrapped in RedactingLogger: tokens never reach your logs
    ->withAuditLog(new JsonlAuditLog('/var/log/workbench-audit.log'))
    ->withHttpClient($anyPsr18Client);              // optional; Guzzle otherwise

$do = DigitalOcean::make(options: $options);
```

| Behaviour | Default |
|---|---|
| Timeouts | 30 s total, 10 s connect |
| Retries | 4 attempts, exponential backoff 500 ms → 20 s cap, with jitter |
| Rate limits | Quota headers are tracked (`x-ratelimit-*`, `ratelimit-*`); when the quota is spent and resets soon the next request waits for it. GitHub's 403 with `x-ratelimit-remaining: 0` is treated as a 429 |
| What is retried | `429` always (honouring `Retry-After`, capped at 120 s); `5xx` and network errors only for idempotent methods (GET, HEAD, PUT, DELETE, OPTIONS). A `POST` is never replayed |
| Redirects | Refused (`3xx` is an error) so a bearer token is never forwarded to another host |
| Paths | Validated (`/v2/...` shape, no `..`); IDs and names are validated before any request |
| User-Agent | `server-infra-workbench/<version>` (`withUserAgent()` to change) |

## Errors

All exceptions implement `Exception\WorkbenchException`.

| Exception | When |
|---|---|
| `ValidationException` | Bad input (id, zone, DNS name, IP, ttl) caught before any request |
| `CredentialException` | Token or key missing, or the credentials file has unsafe permissions |
| `AuthenticationException` | HTTP 401/403 |
| `NotFoundException` | HTTP 404 |
| `ApiValidationException` | HTTP 400/422; the message includes the API's field errors |
| `RateLimitException` | HTTP 429 after retries ran out (`->retryAfter` seconds when the API sent one) |
| `ApiException` | Any other non-2xx (`->provider`, `->status`) |
| `TransportException` / `TimeoutException` | Network failure / an action or operation did not finish in time |
| `ActionFailedException` | A DigitalOcean action or GCP operation finished with an error |
| `ConfirmationRequiredException` | `confirm()` called twice, or the CLI was not given `--yes`/`--force` |

Messages and logs pass through `Redactor`: known secrets, bearer/basic headers, `dop_v1_…`, `ya29.…`, PEM keys
and `token=`/`"password":` style values are masked as `***`.

## Credentials

Resolved in this order; the first hit wins ([ADR 0005](../adr/0005-credentials-outside-the-repo.md)):

1. A value passed to `make()` (string or `Security\Secret`).
2. The environment variable.
3. The credentials file: `$SIW_CREDENTIALS_FILE`, else `~/.config/server-infra-workbench/credentials`.
   `KEY=VALUE` lines; the file must be **mode 600, owned by you, and outside any git working tree**, or it is
   refused.

| Key | Used by |
|---|---|
| `DIGITALOCEAN_TOKEN` | DigitalOcean personal access token (read scope for reads; write for snapshots) |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token on the zones you manage: `Zone:Read` + `DNS:Edit`, plus Zone Settings, SSL and Certificates, Cache Purge, Firewall Services as used ([cloudflare](../providers/cloudflare.md)) |
| `PLOI_API_TOKEN` | Ploi API token |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to a service-account JSON key (mode 600, outside any repo) |
| `GCP_PROJECT` | Default project (else the key's `project_id`) |
| `GITHUB_TOKEN` | GitHub fine-grained token on the repositories you manage ([github](../providers/github.md)) |

GCP auth: an explicit `TokenProvider`; else the service-account key (RS256 JWT exchanged for an OAuth token,
cached per scope until shortly before expiry); else `gcloud auth print-access-token` (run without a shell).
Reads request read-only scopes (`compute.readonly`, `ndev.clouddns.readonly`, `devstorage.read_only`); writes
request the matching write scope only when confirmed.

Tokens are wrapped in `Secret` (prints as `***`, refuses serialization). See [configuration](../configuration.md)
for the file format.

## Audit log

Every `plan()` and `confirm()` appends one JSON line (time, provider, action, target, method, path, outcome,
error) to `$SIW_AUDIT_LOG`, else `~/.local/state/server-infra-workbench/audit.log` (directory 700, file 600).
Payloads and tokens are not written. `SIW_AUDIT_LOG=off` disables it.

## Testing

`make php` runs Pint (`--test`), PHPStan and PHPUnit. Tests use a queued mock PSR-18 client and a recording
sleeper: no network, no real waits, no credentials. `phpunit.xml` forces `SIW_AUDIT_LOG=off` and points the
credentials file at a path that does not exist, so a developer's real file is never read. Contract tests cover
each provider's pagination, retries, `Retry-After`, quota waits and error mapping.

Live read-only tests (`tests/Live`, testsuite `live`, not in the default run) need `SIW_LIVE=1` and a token, and
use a client that refuses anything but GET (and the Google token exchange):

```bash
cd src/php && SIW_LIVE=1 vendor/bin/phpunit --testsuite live    # providers without a token are skipped
```

## Adding a platform

1. `src/<Platform>/<Platform>.php` with `make()` building a `Transport` (base URL, `BearerToken`, options).
2. A `Paginator` for its list format, resource classes with typed methods, DTOs in `Data/` using
   `Support\Data` for strict casts.
3. Writes return `$transport->pending(...)`; mark deletes destructive.
4. Mocked tests in `tests/Unit/<Platform>Test.php`, a `Console\Commands\<Platform>Command` routed from
   `Console\Application`, help in `Console\Help`, a page in `docs/providers/` and a section here.
