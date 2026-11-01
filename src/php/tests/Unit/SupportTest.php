<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Unit;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\RetryPolicy;
use Simtabi\ServerInfraWorkbench\Safety\AuditEntry;
use Simtabi\ServerInfraWorkbench\Safety\JsonlAuditLog;
use Simtabi\ServerInfraWorkbench\Support\Validate;
use Simtabi\ServerInfraWorkbench\Tests\TestCase;

final class SupportTest extends TestCase
{
    public function test_validators(): void
    {
        self::assertSame(12, Validate::id('12'));
        self::assertSame('example.com', Validate::domain('Example.COM.'));
        self::assertSame('_dmarc.example.com', Validate::dnsName('_dmarc.example.com'));
        self::assertSame('*.example.com', Validate::dnsName('*.example.com'));
        self::assertSame('db-disk-1', Validate::gcpName('db-disk-1'));

        foreach ([
            static fn () => Validate::id('1e3'),
            static fn () => Validate::domain('exa mple.com'),
            static fn () => Validate::domain('-bad.com'),
            static fn () => Validate::gcpName('Upper'),
            static fn () => Validate::label('x;rm'),
            static fn () => Validate::token('../etc'),
        ] as $i => $bad) {
            try {
                $bad();
                self::fail("validator {$i} accepted bad input");
            } catch (ValidationException) {
            }
        }
    }

    public function test_retry_policy_is_immutable_and_bounded(): void
    {
        $policy = RetryPolicy::default()->withJitter(false)->withBackoff(100, 300);

        self::assertSame([100, 200, 300, 300], [$policy->delayMs(1), $policy->delayMs(2), $policy->delayMs(3), $policy->delayMs(9)]);
        self::assertSame(120_000, $policy->delayMs(1, 999));
        self::assertTrue($policy->shouldRetry(1, 503, true));
        self::assertFalse($policy->shouldRetry(1, 503, false));
        self::assertTrue($policy->shouldRetry(1, 429, false));
        self::assertFalse($policy->shouldRetry(4, 429, true));
        self::assertSame(4, RetryPolicy::default()->maxAttempts(), 'withers must not mutate the original');
    }

    public function test_jsonl_audit_log_is_private_and_redacted(): void
    {
        $path = $this->tempDir().'/state/audit.log';
        $log = new JsonlAuditLog($path);
        $log->record(new AuditEntry('2026-10-31T00:00:00Z', 'confirmed', 'Test', 'do thing', 't', 'POST', '/x', ['name' => 'n'], false, 'sim'));
        $log->record(new AuditEntry('2026-10-31T00:00:01Z', 'succeeded', 'Test', 'do thing', 't', 'POST', '/x', [], false, 'sim'));

        $lines = file($path, FILE_IGNORE_NEW_LINES);
        self::assertIsArray($lines);
        self::assertCount(2, $lines);
        $first = json_decode($lines[0], true, flags: JSON_THROW_ON_ERROR);
        self::assertIsArray($first);
        self::assertSame('confirmed', $first['outcome']);
        self::assertSame(0o600, fileperms($path) & 0o777);
        self::assertSame(0o700, fileperms(dirname($path)) & 0o777);
    }
}
