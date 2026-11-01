<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Http;

use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Psr7\HttpFactory;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestFactoryInterface;
use Psr\Http\Message\StreamFactoryInterface;
use Psr\Log\LoggerInterface;
use Psr\Log\NullLogger;
use Simtabi\ServerInfraWorkbench\Safety\AuditLog;
use Simtabi\ServerInfraWorkbench\Safety\JsonlAuditLog;

/**
 * Immutable settings shared by every provider client. Each with*() returns a copy.
 * Bring any PSR-18 client and PSR-17 factories; Guzzle is only the default.
 */
final class ClientOptions
{
    public const string VERSION = '0.1.0';

    private ?ClientInterface $http = null;

    private ?RequestFactoryInterface $requests = null;

    private ?StreamFactoryInterface $streams = null;

    private float $timeout = 30.0;

    private float $connectTimeout = 10.0;

    private RetryPolicy $retry;

    private LoggerInterface $logger;

    private ?AuditLog $audit = null;

    private Sleeper $sleeper;

    private string $userAgent = 'server-infra-workbench/'.self::VERSION;

    private function __construct()
    {
        $this->retry = RetryPolicy::default();
        $this->logger = new NullLogger;
        $this->sleeper = new SystemSleeper;
    }

    public static function defaults(): self
    {
        return new self;
    }

    public function withHttpClient(ClientInterface $client, ?RequestFactoryInterface $requests = null, ?StreamFactoryInterface $streams = null): self
    {
        $clone = clone $this;
        $clone->http = $client;
        $clone->requests = $requests ?? $this->requests;
        $clone->streams = $streams ?? $this->streams;

        return $clone;
    }

    public function withTimeout(float $seconds, ?float $connectSeconds = null): self
    {
        $clone = clone $this;
        $clone->timeout = max(1.0, $seconds);
        $clone->connectTimeout = max(1.0, $connectSeconds ?? min($seconds, $this->connectTimeout));
        if ($this->http instanceof GuzzleClient) {
            $clone->http = null;
        }

        return $clone;
    }

    public function withRetry(RetryPolicy $retry): self
    {
        $clone = clone $this;
        $clone->retry = $retry;

        return $clone;
    }

    public function withLogger(LoggerInterface $logger): self
    {
        $clone = clone $this;
        $clone->logger = $logger;

        return $clone;
    }

    public function withAuditLog(AuditLog $audit): self
    {
        $clone = clone $this;
        $clone->audit = $audit;

        return $clone;
    }

    public function withSleeper(Sleeper $sleeper): self
    {
        $clone = clone $this;
        $clone->sleeper = $sleeper;

        return $clone;
    }

    public function withUserAgent(string $userAgent): self
    {
        $clone = clone $this;
        $clone->userAgent = $userAgent;

        return $clone;
    }

    public function httpClient(): ClientInterface
    {
        return $this->http ??= new GuzzleClient([
            'timeout' => $this->timeout,
            'connect_timeout' => $this->connectTimeout,
            'http_errors' => false,
            'allow_redirects' => false,
        ]);
    }

    public function requestFactory(): RequestFactoryInterface
    {
        return $this->requests ??= new HttpFactory;
    }

    public function streamFactory(): StreamFactoryInterface
    {
        return $this->streams ??= new HttpFactory;
    }

    public function retry(): RetryPolicy
    {
        return $this->retry;
    }

    public function logger(): LoggerInterface
    {
        return $this->logger;
    }

    public function auditLog(): AuditLog
    {
        return $this->audit ??= JsonlAuditLog::default();
    }

    public function sleeper(): Sleeper
    {
        return $this->sleeper;
    }

    public function userAgent(): string
    {
        return $this->userAgent;
    }

    public function timeout(): float
    {
        return $this->timeout;
    }
}
