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
    protected const string TOKEN = 'dop_v1_'.'0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

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
