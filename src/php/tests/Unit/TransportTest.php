<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use GuzzleHttp\Psr7\Request;
use GuzzleHttp\Psr7\Response;
use Psr\Http\Client\NetworkExceptionInterface;
use Psr\Http\Message\RequestInterface;
use Simtabi\VpsServerWorkbench\Exception\ApiValidationException;
use Simtabi\VpsServerWorkbench\Exception\AuthenticationException;
use Simtabi\VpsServerWorkbench\Exception\NotFoundException;
use Simtabi\VpsServerWorkbench\Exception\RateLimitException;
use Simtabi\VpsServerWorkbench\Exception\TransportException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\BearerToken;
use Simtabi\VpsServerWorkbench\Http\RetryPolicy;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Security\Secret;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class TransportTest extends TestCase
{
    private function transport(?RetryPolicy $retry = null): Transport
    {
        $options = $this->options();

        return new Transport('Test', 'https://api.example.test/v1', new BearerToken(new Secret('tok-abcdef-123')), $retry === null ? $options : $options->withRetry($retry));
    }

    public function test_sends_auth_and_json_headers_and_query(): void
    {
        $this->http->json(['ok' => true]);

        $response = $this->transport()->get('/things', ['page' => 2, 'flag' => true]);

        $request = $this->http->last();
        self::assertSame(['ok' => true], $response->json);
        self::assertSame('Bearer tok-abcdef-123', $request->getHeaderLine('Authorization'));
        self::assertSame('application/json', $request->getHeaderLine('Accept'));
        self::assertStringStartsWith('vps-server-workbench/', $request->getHeaderLine('User-Agent'));
        self::assertSame('https://api.example.test/v1/things?page=2&flag=true', (string) $request->getUri());
    }

    public function test_retries_503_with_exponential_backoff_then_succeeds(): void
    {
        $this->http->json([], 503)->json([], 502)->json(['ok' => 1]);

        self::assertSame(['ok' => 1], $this->transport()->get('/x')->json);
        self::assertSame([100, 200], $this->sleeper->sleeps);
        self::assertCount(3, $this->http->requests);
    }

    public function test_honours_retry_after_on_429_even_for_post(): void
    {
        $this->http->json([], 429, ['Retry-After' => '7'])->json(['id' => 1], 201);

        self::assertSame(201, $this->transport()->send('POST', '/x', [], ['a' => 1])->status);
        self::assertSame([7000], $this->sleeper->sleeps);
    }

    public function test_never_retries_a_post_on_5xx(): void
    {
        $this->http->json(['message' => 'boom'], 500);

        try {
            $this->transport()->send('POST', '/x', [], []);
            self::fail('expected exception');
        } catch (\Simtabi\VpsServerWorkbench\Exception\ApiException $e) {
            self::assertSame(500, $e->status);
            self::assertStringContainsString('boom', $e->getMessage());
        }
        self::assertCount(1, $this->http->requests);
        self::assertSame([], $this->sleeper->sleeps);
    }

    public function test_gives_up_after_max_attempts_with_rate_limit_exception(): void
    {
        $this->http->json([], 429)->json([], 429)->json([], 429, ['Retry-After' => '30']);

        try {
            $this->transport(RetryPolicy::default()->withJitter(false)->withMaxAttempts(3)->withBackoff(10, 10))->get('/x');
            self::fail('expected exception');
        } catch (RateLimitException $e) {
            self::assertSame(30, $e->retryAfter);
        }
        self::assertCount(3, $this->http->requests);
    }

    public function test_retries_network_errors_on_reads_only(): void
    {
        $error = new class('connection reset') extends \RuntimeException implements NetworkExceptionInterface
        {
            public function getRequest(): RequestInterface
            {
                return new Request('GET', 'https://x');
            }
        };
        $this->http->push($error)->json(['ok' => 1]);
        self::assertSame(['ok' => 1], $this->transport()->get('/x')->json);

        $this->http->push($error);
        $this->expectException(TransportException::class);
        $this->transport()->send('POST', '/x', [], []);
    }

    /** @return iterable<string, array{int, class-string<\Throwable>}> */
    public static function statuses(): iterable
    {
        yield '401' => [401, AuthenticationException::class];
        yield '403' => [403, AuthenticationException::class];
        yield '404' => [404, NotFoundException::class];
        yield '422' => [422, ApiValidationException::class];
    }

    /** @param class-string<\Throwable> $class */
    #[\PHPUnit\Framework\Attributes\DataProvider('statuses')]
    public function test_maps_status_codes_to_typed_exceptions(int $status, string $class): void
    {
        $this->http->json(['message' => 'nope', 'errors' => ['name' => ['is required']]], $status);

        $this->expectException($class);
        $this->expectExceptionMessageMatches('/HTTP '.$status.'.*nope.*name: is required/');
        $this->transport()->get('/x');
    }

    public function test_refuses_redirects_so_tokens_are_not_forwarded(): void
    {
        $this->http->push(new Response(302, ['Location' => 'https://evil.test/']));

        $this->expectException(TransportException::class);
        $this->expectExceptionMessageMatches('/redirect/');
        $this->transport()->get('/x');
    }

    public function test_rejects_path_traversal_and_injection(): void
    {
        $this->expectException(ValidationException::class);
        $this->transport()->get('/x/../admin');
    }

    public function test_logs_are_redacted(): void
    {
        $this->http->json(['ok' => 1]);
        $this->transport()->get('/x', ['token' => 'tok-'.'abcdef-123']);

        self::assertNotSame([], $this->logger->lines);
        self::assertStringNotContainsString('tok-abcdef-123', $this->logger->all());
        self::assertStringContainsString('-> 200', $this->logger->all());
    }

    public function test_error_messages_are_redacted(): void
    {
        $this->http->json(['message' => 'bad token tok-abcdef-123'], 401);

        try {
            $this->transport()->get('/x');
            self::fail('expected exception');
        } catch (AuthenticationException $e) {
            self::assertStringNotContainsString('tok-abcdef-123', $e->getMessage());
        }
    }
}
