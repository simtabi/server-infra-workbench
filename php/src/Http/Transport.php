<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

use Psr\Http\Client\ClientExceptionInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;
use Simtabi\VpsServerWorkbench\Exception\ApiException;
use Simtabi\VpsServerWorkbench\Exception\TransportException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Security\RedactingLogger;
use Simtabi\VpsServerWorkbench\Security\Redactor;

/**
 * The one place HTTP happens: auth, JSON, retries with backoff, Retry-After, timeouts (via the PSR-18
 * client), pagination, error mapping and redacted logging. Provider classes only describe endpoints.
 */
final class Transport
{
    private const array IDEMPOTENT = ['GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'];

    private readonly RedactingLogger $logger;

    public function __construct(
        private readonly string $provider,
        private readonly string $baseUrl,
        private readonly Authenticator $auth,
        private readonly ClientOptions $options,
        private Redactor $redactor = new Redactor,
    ) {
        $this->redactor = $this->redactor->withSecret(...$auth->secrets());
        $this->logger = new RedactingLogger($options->logger(), $this->redactor);
    }

    public function provider(): string
    {
        return $this->provider;
    }

    public function options(): ClientOptions
    {
        return $this->options;
    }

    public function redactor(): Redactor
    {
        return $this->redactor->withSecret(...$this->auth->secrets());
    }

    /** @param array<string, int|string|bool> $query */
    public function get(string $path, array $query = []): ApiResponse
    {
        return $this->send('GET', $path, $query);
    }

    /**
     * @param array<string, int|string|bool> $query
     * @param array<mixed>|null              $body
     */
    public function send(string $method, string $path, array $query = [], ?array $body = null): ApiResponse
    {
        $method = strtoupper($method);
        $idempotent = in_array($method, self::IDEMPOTENT, true);
        $write = ! in_array($method, ['GET', 'HEAD', 'OPTIONS'], true);
        $uri = $this->uri($path, $query);
        $shown = $this->redactor()->redact($uri);
        $retry = $this->options->retry();

        for ($attempt = 1; ; $attempt++) {
            $started = hrtime(true);

            try {
                $response = $this->options->httpClient()->sendRequest($this->request($method, $uri, $body, $write));
            } catch (ClientExceptionInterface $e) {
                $reason = $this->redactor()->redact($e->getMessage());
                if ($retry->shouldRetryNetworkError($attempt, $idempotent)) {
                    $delay = $retry->delayMs($attempt);
                    $this->logger->warning('{provider} {method} {uri} network error, retry {attempt} in {delay} ms: {reason}', compact('method', 'attempt', 'delay', 'reason') + ['provider' => $this->provider, 'uri' => $shown]);
                    $this->options->sleeper()->sleep($delay);

                    continue;
                }

                throw new TransportException(sprintf('%s %s %s: %s', $this->provider, $method, $shown, $reason));
            }

            $status = $response->getStatusCode();
            $this->logger->debug('{provider} {method} {uri} -> {status} ({ms} ms)', [
                'provider' => $this->provider, 'method' => $method, 'uri' => $shown, 'status' => $status,
                'ms' => intdiv(hrtime(true) - $started, 1_000_000),
            ]);

            if ($retry->shouldRetry($attempt, $status, $idempotent)) {
                $delay = $retry->delayMs($attempt, self::retryAfter($response));
                $this->logger->notice('{provider} {method} {uri} -> {status}, retry {attempt} in {delay} ms', [
                    'provider' => $this->provider, 'method' => $method, 'uri' => $shown, 'status' => $status, 'attempt' => $attempt, 'delay' => $delay,
                ]);
                $this->options->sleeper()->sleep($delay);

                continue;
            }

            $api = ApiResponse::from($response);
            if ($status >= 400) {
                throw ApiException::fromResponse($this->provider, $method, $shown, $status, $this->redactor()->redactArray($api->json), self::retryAfter($response));
            }
            if ($status >= 300) {
                throw new TransportException(sprintf('%s %s %s: unexpected redirect (HTTP %d) — refusing to follow with credentials', $this->provider, $method, $shown, $status));
            }

            return $api;
        }
    }

    /**
     * Walks every page lazily.
     *
     * @param array<string, int|string|bool> $query
     * @return \Generator<int, array<string, mixed>>
     */
    public function paginate(string $path, array $query, Paginator $paginator, int $maxPages = 500): \Generator
    {
        for ($page = 1; $page <= $maxPages; $page++) {
            $json = $this->get($path, $query)->json;
            yield from $paginator->items($json);
            $next = $paginator->next($json, $query);
            if ($next === null || $next === $query) {
                return;
            }
            $query = $next;
        }
        $this->logger->warning('{provider} {path}: stopped after {max} pages', ['provider' => $this->provider, 'path' => $path, 'max' => $maxPages]);
    }

    /**
     * Builds a write that only runs when confirmed.
     *
     * @template T
     *
     * @param array<mixed>  $payload
     * @param \Closure(): T $run
     * @return PendingAction<T>
     */
    public function pending(string $action, string $target, string $method, string $path, array $payload, \Closure $run, bool $destructive = false, ?string $note = null): PendingAction
    {
        return new PendingAction($this->provider, $action, $target, $method, $path, $payload, $run, $this->options->auditLog(), $this->redactor(), $destructive, $note);
    }

    /** @param array<string, int|string|bool> $query */
    private function uri(string $path, array $query): string
    {
        if (preg_match('#^/[A-Za-z0-9/_.:@%-]*$#', $path) !== 1 || str_contains($path, '..')) {
            throw new ValidationException(sprintf('refusing unsafe request path "%s"', $path));
        }
        $uri = rtrim($this->baseUrl, '/').$path;
        $query = array_map(static fn (int|string|bool $v): int|string => is_bool($v) ? ($v ? 'true' : 'false') : $v, $query);

        return $query === [] ? $uri : $uri.'?'.http_build_query($query, '', '&', PHP_QUERY_RFC3986);
    }

    /** @param array<mixed>|null $body */
    private function request(string $method, string $uri, ?array $body, bool $write): RequestInterface
    {
        $request = $this->options->requestFactory()->createRequest($method, $uri)
            ->withHeader('Accept', 'application/json')
            ->withHeader('User-Agent', $this->options->userAgent());

        if ($body !== null) {
            try {
                $json = json_encode($body === [] ? new \stdClass : $body, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
            } catch (\JsonException $e) {
                throw new ValidationException('request body is not JSON-encodable: '.$e->getMessage());
            }
            $request = $request->withHeader('Content-Type', 'application/json')
                ->withBody($this->options->streamFactory()->createStream($json));
        }

        return $this->auth->authorize($request, $write);
    }

    private static function retryAfter(ResponseInterface $response): ?int
    {
        $value = trim($response->getHeaderLine('Retry-After'));
        if ($value === '') {
            return null;
        }
        if (ctype_digit($value)) {
            return (int) $value;
        }
        $at = strtotime($value);

        return $at === false ? null : max(0, $at - time());
    }
}
