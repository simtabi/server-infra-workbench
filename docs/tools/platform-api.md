# Platform API library (`php/`)

Typed, fluent PHP clients for **DigitalOcean**, **Cloudflare**, **Ploi** and **Google Compute Engine**, sharing
one HTTP core. The [`bin/workbench` CLI](cli.md) is a thin layer over this library; you can also use it from any
PHP 8.4+ project or script.

- **Namespace** `Simtabi\VpsServerWorkbench\` (PSR-4, `php/src/`), package `simtabi/vps-server-workbench`.
- **Standards** PSR-18 HTTP client and PSR-17 factories (Guzzle by default; inject any client), PSR-3 logger,
  PSR-12/PER style enforced by Pint, PHPStan level `max` with strict rules.
- **No vendor SDKs.** Each platform is a few small classes over the same `Transport` (see
  [ADR 0003](../adr/0003-php-platform-clients-on-psr-18.md)).
- **Read-only by default.** Every write returns a `PendingAction`; nothing is sent until you call `confirm()`
  ([ADR 0004](../adr/0004-writes-are-pending-actions.md)).

## Install

```bash
composer install --working-dir=php          # from the repo root; locked versions, PHP 8.4+
make php                                    # pint --test, phpstan, phpunit
```

In another project, add this repo as a Composer `path` (or `vcs`) repository and
`composer require simtabi/vps-server-workbench`.

## Quick start

```php
use Simtabi\VpsServerWorkbench\DigitalOcean\DigitalOcean;

$do = DigitalOcean::make();                                  // token from DIGITALOCEAN_TOKEN or the credentials file

foreach ($do->droplets()->list(tag: 'db') as $droplet) {
    echo $droplet->name, ' ', $droplet->status->value, ' ', $droplet->privateIpv4, PHP_EOL;
}

$snapshot = $do->droplets()->snapshot(123456, 'db-pre-upgrade');   // PendingAction - nothing sent yet
print_r($snapshot->plan());                                          // dry run: method, path, payload (audited as dry-run)
$action = $snapshot->confirm()->wait(timeoutSeconds: 1800);          // send, then poll until completed/errored
```

```php
use Simtabi\VpsServerWorkbench\Cloudflare\Cloudflare;

$dns = Cloudflare::make()->dns('example.com');               // zone by name or 32-char id
$dns->upsert('A', 'db', '203.0.113.10', ttl: 300)->confirm(); // create, update or no-op; refuses duplicates
$dns->list(type: 'CNAME');
$dns->delete($recordId)->confirm();                           // destructive: PendingAction::isDestructive() === true
```

```php
use Simtabi\VpsServerWorkbench\Ploi\Ploi;

$server = Ploi::make()->servers()->find(42);                  // lazy, scoped handle; no request yet
$server->get();                                               // Server DTO
$server->sites()->list();
$server->sites()->deploy(1001)->confirm();
```

```php
use Simtabi\VpsServerWorkbench\Gcp\Gcp;

$gcp = Gcp::make('my-project');                               // service-account key or gcloud, see Credentials
$gcp->instances()->list();                                    // all zones (aggregated)
foreach ($gcp->firewalls()->list() as $rule) {
    if ($rule->isOpenToWorld()) { echo "open to 0.0.0.0/0: {$rule->name}\n"; }
}
$gcp->snapshots()->create('us-east1-b', 'db-disk', 'db-pre-upgrade')->confirm()->wait();
```

## API surface

| Entry point | Reads | Writes (return `PendingAction`) |
|---|---|---|
| `DigitalOcean::make($token?)` | `droplets()->list(?tag)`, `->find(id)`, `->snapshots(id)`, `snapshots()->list(type)`, `->find(id)`, `actions()->find(id)`, `account()` | `droplets()->snapshot(id, ?name)` → `RunningAction` (`->wait()`); `snapshots()->delete(id)` **destructive** |
| `Cloudflare::make($token?)` | `zones()->list(?name)`, `->find(zone)`, `dns(zone)->list(?type, ?name)`, `verifyToken()` | `dns(zone)->upsert(type, name, content, ttl, proxied, priority, comment)`; `->delete(id)` **destructive** |
| `Ploi::make($token?)` | `servers()->list()`, `->get(id)`, `->find(id)->get()`, `->find(id)->sites()->list()`, `->find(id)` | `servers()->find(id)->sites()->deploy(siteId)` |
| `Gcp::make($project?, $tokens?)` | `instances()->list(?zone)`, `->find(zone, name)`, `snapshots()->list()`, `firewalls()->list()` | `snapshots()->create(zone, disk, ?name)` → `RunningOperation`; `->delete(name)` **destructive** |

Lists follow pagination for you (DigitalOcean `links.pages.next`, Cloudflare `result_info`, Ploi `links.next`,
GCP `nextPageToken`) and return typed, immutable DTOs (`Droplet`, `Snapshot`, `Action`, `Zone`, `DnsRecord`,
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
use Simtabi\VpsServerWorkbench\Http\{ClientOptions, RetryPolicy};
use Simtabi\VpsServerWorkbench\Safety\JsonlAuditLog;

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
| What is retried | `429` always (honouring `Retry-After`, capped at 120 s); `5xx` and network errors only for idempotent methods (GET, HEAD, PUT, DELETE, OPTIONS). A `POST` is never replayed |
| Redirects | Refused (`3xx` is an error) so a bearer token is never forwarded to another host |
| Paths | Validated (`/v2/...` shape, no `..`); IDs and names are validated before any request |
| User-Agent | `vps-server-workbench/<version>` (`withUserAgent()` to change) |

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
3. The credentials file: `$VSW_CREDENTIALS_FILE`, else `~/.config/vps-server-workbench/credentials`.
   `KEY=VALUE` lines; the file must be **mode 600, owned by you, and outside any git working tree**, or it is
   refused.

| Key | Used by |
|---|---|
| `DIGITALOCEAN_TOKEN` | DigitalOcean personal access token (read scope for reads; write for snapshots) |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token scoped to `Zone:Read` + `DNS:Edit` on the zones you manage |
| `PLOI_API_TOKEN` | Ploi API token |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to a service-account JSON key (mode 600, outside any repo) |
| `GCP_PROJECT` | Default project (else the key's `project_id`) |

GCP auth: an explicit `TokenProvider`; else the service-account key (RS256 JWT exchanged for an OAuth token,
cached per scope until shortly before expiry); else `gcloud auth print-access-token` (run without a shell).
Reads request the `compute.readonly` scope; writes request `compute`.

Tokens are wrapped in `Secret` (prints as `***`, refuses serialization). See [configuration](../configuration.md)
for the file format.

## Audit log

Every `plan()` and `confirm()` appends one JSON line (time, provider, action, target, method, path, outcome,
error) to `$VSW_AUDIT_LOG`, else `~/.local/state/vps-server-workbench/audit.log` (directory 700, file 600).
Payloads and tokens are not written. `VSW_AUDIT_LOG=off` disables it.

## Testing

`make php` runs Pint (`--test`), PHPStan and PHPUnit. Tests use a queued mock PSR-18 client and a recording
sleeper: no network, no real waits, no credentials. `phpunit.xml` forces `VSW_AUDIT_LOG=off` and points the
credentials file at a path that does not exist, so a developer's real file is never read.

## Adding a platform

1. `src/<Platform>/<Platform>.php` with `make()` building a `Transport` (base URL, `BearerToken`, options).
2. A `Paginator` for its list format, resource classes with typed methods, DTOs in `Data/` using
   `Support\Data` for strict casts.
3. Writes return `$transport->pending(...)`; mark deletes destructive.
4. Mocked tests in `tests/Unit/<Platform>Test.php`, CLI commands in `Console\Application`, and a section here.
