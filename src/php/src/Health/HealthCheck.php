<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Health;

use Psr\Http\Client\ClientExceptionInterface;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;

/**
 * A doctor-style check of public health endpoints (e.g. https://app.example.com/up): status code,
 * an optional body substring, and a latency budget. Read-only, unauthenticated, redirects not followed.
 * TLS expiry is better watched by a DigitalOcean ssl_expiry alert (workbench do uptime alert-create).
 */
final readonly class HealthCheck
{
    public function __construct(private ClientOptions $options) {}

    public function check(string $url, int $expectStatus = 200, ?string $contains = null, ?int $maxMs = null): HealthResult
    {
        $parts = parse_url($url);
        if (! is_array($parts) || ! in_array($parts['scheme'] ?? '', ['http', 'https'], true) || ($parts['host'] ?? '') === '') {
            throw new ValidationException(sprintf('"%s" is not an http(s) URL', $url));
        }
        $request = $this->options->requestFactory()->createRequest('GET', $url)->withHeader('User-Agent', $this->options->userAgent());
        $start = hrtime(true);
        try {
            $response = $this->options->httpClient()->sendRequest($request);
        } catch (ClientExceptionInterface $e) {
            return new HealthResult($url, false, null, $this->since($start), ['unreachable: '.$e->getMessage()]);
        }
        $ms = $this->since($start);
        $problems = [];
        if ($response->getStatusCode() !== $expectStatus) {
            $problems[] = sprintf('status %d, expected %d', $response->getStatusCode(), $expectStatus);
        }
        if ($contains !== null && ! str_contains((string) $response->getBody(), $contains)) {
            $problems[] = sprintf('body does not contain "%s"', $contains);
        }
        if ($maxMs !== null && $ms > $maxMs) {
            $problems[] = sprintf('took %d ms, budget %d ms', $ms, $maxMs);
        }

        return new HealthResult($url, $problems === [], $response->getStatusCode(), $ms, $problems);
    }

    private function since(int $start): int
    {
        return intdiv(hrtime(true) - $start, 1_000_000);
    }
}
