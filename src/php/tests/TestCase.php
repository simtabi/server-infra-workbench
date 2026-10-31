<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests;

use PHPUnit\Framework\TestCase as Base;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Http\RetryPolicy;
use Simtabi\VpsServerWorkbench\Safety\InMemoryAuditLog;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MemoryLogger;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\RecordingSleeper;

abstract class TestCase extends Base
{
    /** Repo rule: no hardcoded secrets, not even in tests. Every run gets fresh values. */
    private static ?string $doToken = null;

    /** A DigitalOcean-shaped token (dop_v1_ + 64 hex), generated once per test run. */
    protected static function token(): string
    {
        return self::$doToken ??= 'dop_v1_'.bin2hex(random_bytes(32));
    }

    /** @var array<string, string> */
    private static array $fakes = [];

    /** A named fake credential (e.g. fake('do') -> "do-<random hex>"), stable within one run so tests can assert on it. */
    protected static function fake(string $name): string
    {
        return self::$fakes[$name] ??= $name.'-'.bin2hex(random_bytes(12));
    }

    /** A fresh random secret, e.g. for redaction tests: prefix + 24 hex chars. */
    protected static function secret(string $prefix = 's-'): string
    {
        return $prefix.bin2hex(random_bytes(12));
    }

    protected MockHttpClient $http;

    protected RecordingSleeper $sleeper;

    protected InMemoryAuditLog $audit;

    protected MemoryLogger $logger;

    protected function setUp(): void
    {
        $this->http = new MockHttpClient;
        $this->sleeper = new RecordingSleeper;
        $this->audit = new InMemoryAuditLog;
        $this->logger = new MemoryLogger;
    }

    protected function options(): ClientOptions
    {
        return ClientOptions::defaults()
            ->withHttpClient($this->http)
            ->withSleeper($this->sleeper)
            ->withAuditLog($this->audit)
            ->withLogger($this->logger)
            ->withRetry(RetryPolicy::default()->withJitter(false)->withBackoff(100, 1000));
    }

    protected function tempDir(): string
    {
        $dir = sys_get_temp_dir().'/vsw-php-test-'.bin2hex(random_bytes(6));
        mkdir($dir, 0o700, true);
        register_shutdown_function(static function () use ($dir): void {
            exec('rm -rf '.escapeshellarg($dir));
        });

        return $dir;
    }
}
