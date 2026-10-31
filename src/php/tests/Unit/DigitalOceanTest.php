<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\ActionStatus;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\DropletStatus;
use Simtabi\VpsServerWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\VpsServerWorkbench\Exception\ActionFailedException;
use Simtabi\VpsServerWorkbench\Exception\CredentialException;
use Simtabi\VpsServerWorkbench\Exception\TimeoutException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class DigitalOceanTest extends TestCase
{
    private function do(): DigitalOcean
    {
        return DigitalOcean::make(self::token(), $this->options());
    }

    /** @return array<string, mixed> */
    private static function droplet(int $id, string $name): array
    {
        return [
            'id' => $id, 'name' => $name, 'status' => 'active', 'memory' => 2048, 'vcpus' => 2, 'disk' => 50,
            'region' => ['slug' => 'nyc3'], 'size_slug' => 's-2vcpu-2gb', 'tags' => ['db'], 'created_at' => '2026-01-01T00:00:00Z',
            'networks' => ['v4' => [['type' => 'private', 'ip_address' => '10.0.0.5'], ['type' => 'public', 'ip_address' => '203.0.113.7']]],
        ];
    }

    public function test_lists_droplets_across_pages(): void
    {
        $this->http
            ->json(['droplets' => [self::droplet(1, 'web')], 'links' => ['pages' => ['next' => 'https://api.digitalocean.com/v2/droplets?page=2&per_page=200']]])
            ->json(['droplets' => [self::droplet(2, 'db')], 'links' => []]);

        $droplets = $this->do()->droplets()->list();

        self::assertCount(2, $droplets);
        self::assertSame('db', $droplets[1]->name);
        self::assertSame(DropletStatus::Active, $droplets[1]->status);
        self::assertSame('10.0.0.5', $droplets[1]->privateIpv4);
        self::assertSame('203.0.113.7', $droplets[1]->publicIpv4);
        self::assertSame(['GET /v2/droplets?per_page=200', 'GET /v2/droplets?page=2&per_page=200'], $this->http->log());
        self::assertSame('Bearer '.self::token(), $this->http->last()->getHeaderLine('Authorization'));
    }

    public function test_snapshot_is_pending_until_confirmed(): void
    {
        $pending = $this->do()->droplets()->snapshot(123, 'pre-upgrade');

        self::assertSame([], $this->http->requests, 'building a write must not call the API');
        $plan = $pending->plan();
        self::assertSame('POST', $plan['method']);
        self::assertSame('/v2/droplets/123/actions', $plan['path']);
        self::assertSame(['type' => 'snapshot', 'name' => 'pre-upgrade'], $plan['payload']);
        self::assertFalse($plan['destructive']);
        self::assertSame([], $this->http->requests, 'plan() is a dry run');
        self::assertSame(['dry-run'], $this->audit->outcomes());
    }

    public function test_snapshot_confirm_then_wait_polls_until_completed(): void
    {
        $this->http
            ->json(['action' => ['id' => 9, 'status' => 'in-progress', 'type' => 'snapshot', 'resource_id' => 123]], 201)
            ->json(['action' => ['id' => 9, 'status' => 'in-progress', 'type' => 'snapshot']])
            ->json(['action' => ['id' => 9, 'status' => 'completed', 'type' => 'snapshot', 'completed_at' => '2026-10-31T10:00:00Z']]);

        $action = $this->do()->droplets()->snapshot(123, 'pre-upgrade')->confirm()->wait(pollSeconds: 5);

        self::assertSame(ActionStatus::Completed, $action->status);
        self::assertSame(['type' => 'snapshot', 'name' => 'pre-upgrade'], MockHttpClient::body($this->http->requests[0]));
        self::assertSame(['POST /v2/droplets/123/actions', 'GET /v2/actions/9', 'GET /v2/actions/9'], $this->http->log());
        self::assertSame([5000], $this->sleeper->sleeps);
        self::assertSame(['confirmed', 'succeeded'], $this->audit->outcomes());
    }

    public function test_a_pending_action_runs_at_most_once(): void
    {
        $this->http->json(['action' => ['id' => 9, 'status' => 'completed', 'type' => 'snapshot']], 201);
        $pending = $this->do()->droplets()->snapshot(1, 'once');
        $pending->confirm();

        $this->expectException(\LogicException::class);
        $pending->confirm();
    }

    public function test_errored_action_throws(): void
    {
        $this->http
            ->json(['action' => ['id' => 9, 'status' => 'in-progress', 'type' => 'snapshot']], 201)
            ->json(['action' => ['id' => 9, 'status' => 'errored', 'type' => 'snapshot']]);

        $this->expectException(ActionFailedException::class);
        $this->do()->droplets()->snapshot(5, 'x')->confirm()->wait();
    }

    public function test_wait_times_out(): void
    {
        $this->http->json(['action' => ['id' => 9, 'status' => 'in-progress', 'type' => 'snapshot']], 201);
        for ($i = 0; $i < 5; $i++) {
            $this->http->json(['action' => ['id' => 9, 'status' => 'in-progress', 'type' => 'snapshot']]);
        }

        $this->expectException(TimeoutException::class);
        $this->do()->droplets()->snapshot(5, 'x')->confirm()->wait(timeoutSeconds: 20, pollSeconds: 10);
    }

    public function test_failed_confirm_is_audited(): void
    {
        $this->http->json(['id' => 'forbidden', 'message' => 'You do not have access'], 403);

        try {
            $this->do()->droplets()->snapshot(5, 'x')->confirm();
            self::fail('expected exception');
        } catch (\Simtabi\VpsServerWorkbench\Exception\AuthenticationException) {
        }
        self::assertSame(['confirmed', 'failed'], $this->audit->outcomes());
        self::assertStringContainsString('403', (string) $this->audit->entries[1]->error);
    }

    public function test_snapshot_delete_is_destructive(): void
    {
        $pending = $this->do()->snapshots()->delete('1234567');

        self::assertTrue($pending->isDestructive());
        self::assertStringContainsString('[DESTRUCTIVE]', $pending->describe());
        $this->http->push(new \GuzzleHttp\Psr7\Response(204));
        self::assertTrue($pending->confirm());
        self::assertSame(['DELETE /v2/snapshots/1234567'], $this->http->log());
    }

    public function test_validates_ids_and_names_before_any_request(): void
    {
        foreach (['abc', '0', '1/../2', '-5'] as $bad) {
            try {
                $this->do()->droplets()->find($bad);
                self::fail("accepted {$bad}");
            } catch (ValidationException) {
            }
        }
        $this->expectException(ValidationException::class);
        $this->do()->droplets()->snapshot(1, "bad\nname");
    }

    public function test_missing_token_is_a_credential_error(): void
    {
        $this->expectException(CredentialException::class);
        DigitalOcean::make(null, $this->options(), new Credentials(null, []));
    }
}
