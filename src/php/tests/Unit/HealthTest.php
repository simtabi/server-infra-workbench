<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Psr7\Request;
use GuzzleHttp\Psr7\Response;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Health\HealthCheck;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class HealthTest extends TestCase
{
    public function test_ok_status_mismatch_body_and_unreachable(): void
    {
        $this->http->push(new Response(200, [], 'OK app up'))->push(new Response(503, [], 'down'))
            ->push(new ConnectException('connection refused', new Request('GET', 'https://b.example.com/up')));
        $check = new HealthCheck($this->options());
        $ok = $check->check('https://a.example.com/up', 200, 'app up', 60_000);
        self::assertTrue($ok->ok);
        self::assertSame(200, $ok->status);
        self::assertSame('', $this->http->last()->getHeaderLine('Authorization'), 'no credentials are sent');

        $bad = $check->check('https://a.example.com/up', 200, 'app up');
        self::assertFalse($bad->ok);
        self::assertSame(['status 503, expected 200', 'body does not contain "app up"'], $bad->problems);

        $down = $check->check('https://b.example.com/up');
        self::assertNull($down->status);
        self::assertStringStartsWith('unreachable:', $down->problems[0]);
    }

    public function test_latency_budget_and_url_validation(): void
    {
        $this->http->push(static function () {
            usleep(30_000);

            return new Response(200);
        });
        self::assertStringContainsString('budget 1 ms', (new HealthCheck($this->options()))->check('http://a.example.com', 200, null, 1)->problems[0]);
        $this->expectException(ValidationException::class);
        (new HealthCheck($this->options()))->check('file:///etc/passwd');
    }
}
