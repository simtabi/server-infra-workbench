<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\Cloudflare\Cloudflare;
use Simtabi\VpsServerWorkbench\Cloudflare\Data\DnsRecordType;
use Simtabi\VpsServerWorkbench\Exception\ApiException;
use Simtabi\VpsServerWorkbench\Exception\NotFoundException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class CloudflareTest extends TestCase
{
    private const string ZONE_ID = '0123456789abcdef0123456789abcdef';

    private function cf(): Cloudflare
    {
        return Cloudflare::make('cf-token-abcdef', $this->options());
    }

    private function zone(): self
    {
        $this->http->json(['success' => true, 'result' => [['id' => self::ZONE_ID, 'name' => 'example.com', 'status' => 'active', 'plan' => ['name' => 'Free']]], 'result_info' => ['page' => 1, 'total_pages' => 1]]);

        return $this;
    }

    /** @param list<array<string, mixed>> $records */
    private function records(array $records): self
    {
        $this->http->json(['success' => true, 'result' => $records, 'result_info' => ['page' => 1, 'total_pages' => 1]]);

        return $this;
    }

    public function test_lists_dns_records_by_zone_name(): void
    {
        $this->zone()->records([['id' => 'r1', 'type' => 'A', 'name' => 'db.example.com', 'content' => '203.0.113.7', 'ttl' => 1, 'proxied' => false]]);

        $records = $this->cf()->zones()->dns('example.com')->list('a', 'db');

        self::assertSame(DnsRecordType::A, $records[0]->type);
        self::assertSame([
            'GET /client/v4/zones?per_page=50&name=example.com',
            'GET /client/v4/zones/'.self::ZONE_ID.'/dns_records?per_page=100&type=A&name=db.example.com',
        ], $this->http->log());
    }

    public function test_upsert_creates_when_missing(): void
    {
        $this->zone()->records([]);
        $pending = $this->cf()->dns('example.com')->upsert('A', 'db', '203.0.113.7');

        self::assertSame('POST', $pending->plan()['method']);
        $this->http->json(['success' => true, 'result' => ['id' => 'new', 'type' => 'A', 'name' => 'db.example.com', 'content' => '203.0.113.7', 'ttl' => 1]]);
        $record = $pending->confirm();

        self::assertSame('new', $record->id);
        self::assertSame(['type' => 'A', 'name' => 'db.example.com', 'content' => '203.0.113.7', 'ttl' => 1, 'proxied' => false], MockHttpClient::body($this->http->last()));
    }

    public function test_upsert_updates_the_single_existing_record(): void
    {
        $this->zone()->records([['id' => 'r1', 'type' => 'A', 'name' => 'db.example.com', 'content' => '198.51.100.1', 'ttl' => 1]]);
        $pending = $this->cf()->dns('example.com')->upsert(DnsRecordType::A, 'db.example.com', '203.0.113.7');

        $plan = $pending->plan();
        self::assertSame('PUT', $plan['method']);
        self::assertSame('/zones/'.self::ZONE_ID.'/dns_records/r1', $plan['path']);
        self::assertStringContainsString('was 198.51.100.1', (string) $plan['note']);
    }

    public function test_upsert_is_a_noop_when_already_correct(): void
    {
        $this->zone()->records([['id' => 'r1', 'type' => 'A', 'name' => 'db.example.com', 'content' => '203.0.113.7', 'ttl' => 1, 'proxied' => false]]);
        $pending = $this->cf()->dns('example.com')->upsert('A', 'db', '203.0.113.7');

        self::assertTrue($pending->isNoop());
        $before = count($this->http->requests);
        self::assertSame('r1', $pending->confirm()->id);
        self::assertCount($before, $this->http->requests, 'a no-op sends nothing');
    }

    public function test_upsert_refuses_ambiguous_duplicates(): void
    {
        $this->zone()->records([
            ['id' => 'r1', 'type' => 'A', 'name' => 'db.example.com', 'content' => '1.1.1.1'],
            ['id' => 'r2', 'type' => 'A', 'name' => 'db.example.com', 'content' => '1.1.1.2'],
        ]);

        $this->expectException(ValidationException::class);
        $this->expectExceptionMessageMatches('/r1, r2/');
        $this->cf()->dns('example.com')->upsert('A', 'db', '203.0.113.7');
    }

    public function test_validates_record_content_and_zone_membership(): void
    {
        $this->zone();
        $dns = $this->cf()->dns('example.com');

        foreach ([['A', 'db', '999.1.1.1'], ['AAAA', 'db', '1.2.3.4'], ['CNAME', 'www', 'not a host'], ['A', 'db.other.org', '1.2.3.4'], ['BOGUS', 'x', 'y']] as [$type, $name, $content]) {
            try {
                $dns->upsert($type, $name, $content);
                self::fail("accepted {$type} {$name} {$content}");
            } catch (ValidationException) {
            }
        }
        $this->expectException(ValidationException::class);
        $dns->upsert('TXT', 'x', 'v', proxied: true);
    }

    public function test_delete_is_destructive(): void
    {
        $this->zone();
        $pending = $this->cf()->dns('example.com')->delete('abc123');

        self::assertTrue($pending->isDestructive());
        $this->http->json(['success' => true, 'result' => ['id' => 'abc123']]);
        self::assertTrue($pending->confirm());
        self::assertSame('DELETE', $this->http->last()->getMethod());
    }

    public function test_success_false_envelope_is_an_error(): void
    {
        $this->http->json(['success' => false, 'errors' => [['code' => 1003, 'message' => 'Invalid zone']], 'result' => null]);

        $this->expectException(ApiException::class);
        $this->expectExceptionMessageMatches('/1003 Invalid zone/');
        $this->cf()->zones()->list();
    }

    public function test_unknown_zone_is_not_found(): void
    {
        $this->http->json(['success' => true, 'result' => [], 'result_info' => ['page' => 1, 'total_pages' => 1]]);

        $this->expectException(NotFoundException::class);
        $this->cf()->dns('missing.example');
    }
}
