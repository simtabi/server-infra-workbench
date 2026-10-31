<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Fixtures;

use GuzzleHttp\Psr7\Response;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;

/** A PSR-18 client that answers from a script and records every request. No network, ever. */
final class MockHttpClient implements ClientInterface
{
    /** @var list<ResponseInterface|\Throwable|\Closure(RequestInterface): ResponseInterface> */
    private array $queue = [];

    /** @var list<RequestInterface> */
    public array $requests = [];

    /**
     * @param array<mixed>|null     $json
     * @param array<string, string> $headers
     */
    public function json(?array $json, int $status = 200, array $headers = []): self
    {
        $this->queue[] = new Response($status, ['Content-Type' => 'application/json'] + $headers, $json === null ? '' : json_encode($json, JSON_THROW_ON_ERROR));

        return $this;
    }

    public function push(ResponseInterface|\Throwable|\Closure $next): self
    {
        $this->queue[] = $next;

        return $this;
    }

    public function sendRequest(RequestInterface $request): ResponseInterface
    {
        $this->requests[] = $request;
        $next = array_shift($this->queue) ?? throw new \RuntimeException('unexpected request: '.$request->getMethod().' '.$request->getUri());
        if ($next instanceof \Throwable) {
            throw $next;
        }

        return $next instanceof \Closure ? $next($request) : $next;
    }

    public function last(): RequestInterface
    {
        return $this->requests[array_key_last($this->requests) ?? 0] ?? throw new \RuntimeException('no requests were made');
    }

    /** @return list<string> "METHOD path?query" for each request. */
    public function log(): array
    {
        return array_map(static function (RequestInterface $r): string {
            $q = $r->getUri()->getQuery();

            return $r->getMethod().' '.$r->getUri()->getPath().($q === '' ? '' : '?'.$q);
        }, $this->requests);
    }

    public function pending(): int
    {
        return count($this->queue);
    }

    /** @return array<mixed> */
    public static function body(RequestInterface $request): array
    {
        $decoded = json_decode((string) $request->getBody(), true);

        return is_array($decoded) ? $decoded : [];
    }
}
