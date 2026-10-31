<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\VpsServerWorkbench\DigitalOcean\Monitoring;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

/** do resize and Monitoring alert policies. All mocked; no network. */
final class DigitalOceanResizeMonitoringTest extends TestCase
{
    private function do(): DigitalOcean
    {
        return DigitalOcean::make(self::token(), $this->options());
    }

    /** @return array<string, mixed> */
    private static function droplet(string $status = 'active', string $size = 's-1vcpu-2gb'): array
    {
        return ['droplet' => ['id' => 7, 'name' => 'db-1', 'status' => $status, 'region' => ['slug' => 'nyc3'], 'size_slug' => $size, 'memory' => 2048, 'vcpus' => 1, 'disk' => 50, 'networks' => ['v4' => []], 'tags' => [], 'created_at' => '2026-01-01T00:00:00Z']];
    }

    private function action(int $id, string $type, string $status = 'completed'): void
    {
        $this->http->json(['action' => ['id' => $id, 'status' => 'in-progress', 'type' => $type]], 201)
            ->json(['action' => ['id' => $id, 'status' => $status, 'type' => $type]]);
    }

    public function test_resize_plan_is_a_dry_run_and_cpu_ram_only_is_not_destructive(): void
    {
        $this->http->json(self::droplet());
        $pending = $this->do()->droplets()->resize(7, 's-2vcpu-4gb');
        $plan = $pending->plan();
        self::assertSame(['type' => 'resize', 'size' => 's-2vcpu-4gb', 'disk' => false], $plan['payload']);
        self::assertFalse($plan['destructive']);
        self::assertStringContainsString('Snapshot first', (string) $plan['note']);
        self::assertSame(['GET /v2/droplets/7'], $this->http->log());
    }

    public function test_resize_with_disk_is_destructive_and_same_size_is_noop(): void
    {
        $this->http->json(self::droplet());
        self::assertTrue($this->do()->droplets()->resize(7, 's-2vcpu-4gb', disk: true)->isDestructive());
        $this->http->json(self::droplet());
        self::assertTrue($this->do()->droplets()->resize(7, 's-1vcpu-2gb')->isNoop());
    }

    public function test_resize_runs_shutdown_resize_power_on(): void
    {
        $this->http->json(self::droplet());
        $this->action(1, 'shutdown');
        $this->action(2, 'resize');
        $this->action(3, 'power_on');
        $this->http->json(self::droplet('active', 's-2vcpu-4gb'));
        $d = $this->do()->droplets()->resize(7, 's-2vcpu-4gb')->confirm();
        self::assertSame('s-2vcpu-4gb', $d->size);
        $types = [];
        foreach ($this->http->requests as $r) {
            if ($r->getMethod() === 'POST') {
                $types[] = MockHttpClient::body($r)['type'];
            }
        }
        self::assertSame(['shutdown', 'resize', 'power_on'], $types);
        self::assertSame(['confirmed', 'succeeded'], $this->audit->outcomes());
    }

    public function test_resize_falls_back_to_power_off_and_powers_on_after_a_failed_resize(): void
    {
        $this->http->json(self::droplet());
        $this->action(1, 'shutdown', 'errored');
        $this->action(2, 'power_off');
        $this->action(3, 'resize', 'errored');
        $this->action(4, 'power_on');
        try {
            $this->do()->droplets()->resize(7, 's-2vcpu-4gb')->confirm();
            self::fail('resize error must surface');
        } catch (\Simtabi\VpsServerWorkbench\Exception\ActionFailedException) {
            $this->addToAssertionCount(1);
        }
        $types = [];
        foreach ($this->http->requests as $r) {
            if ($r->getMethod() === 'POST') {
                $types[] = MockHttpClient::body($r)['type'];
            }
        }
        self::assertSame(['shutdown', 'power_off', 'resize', 'power_on'], $types);
    }

    public function test_resize_of_a_powered_off_droplet_leaves_it_off(): void
    {
        $this->http->json(self::droplet('off'));
        $this->action(2, 'resize');
        $this->http->json(self::droplet('off', 's-2vcpu-4gb'));
        $this->do()->droplets()->resize(7, 's-2vcpu-4gb')->confirm();
        self::assertSame(['GET /v2/droplets/7', 'POST /v2/droplets/7/actions', 'GET /v2/actions/2', 'GET /v2/droplets/7'], $this->http->log());
    }

    public function test_resize_validates_size(): void
    {
        $this->expectException(ValidationException::class);
        $this->do()->droplets()->resize(7, 'S 2GB');
    }

    public function test_policy_body_and_validation(): void
    {
        $b = Monitoring::body('memory', 90, '10m', ['ops@example.com'], tags: ['db']);
        self::assertSame('v1/insights/droplet/memory_utilization_percent', $b['type']);
        self::assertSame('workbench: memory > 90% for 10m on tag db', $b['description']);
        self::assertSame(['db'], $b['tags']);
        foreach ([
            ['nope', 1, '5m', ['a@b.co'], [1], []],
            ['cpu', 120, '5m', ['a@b.co'], [1], []],
            ['cpu', 80, '7m', ['a@b.co'], [1], []],
            ['cpu', 80, '5m', [], [1], []],
            ['cpu', 80, '5m', ['not-an-email'], [1], []],
            ['cpu', 80, '5m', ['a@b.co'], [], []],
            ['cpu', 80, '5m', ['a@b.co'], [1], ['db']],
        ] as [$type, $value, $window, $emails, $ids, $tags]) {
            try {
                Monitoring::body($type, $value, $window, $emails, $ids, $tags);
                self::fail("{$type} {$value} {$window}");
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function test_standard_creates_only_missing_policies(): void
    {
        $bodies = Monitoring::standard(['ops@example.com'], [7]);
        self::assertCount(3, $bodies);
        $existing = ['uuid' => 'u-1', 'type' => $bodies[0]['type'], 'description' => $bodies[0]['description'], 'compare' => 'GreaterThan', 'value' => 85, 'window' => '10m', 'entities' => ['7'], 'tags' => [], 'alerts' => ['email' => ['ops@example.com']], 'enabled' => true];
        $this->http->json(['policies' => [$existing], 'links' => []]);
        $pending = $this->do()->monitoring()->apply($bodies);
        self::assertStringContainsString('2 new of 3', $pending->describe());
        $this->http->json(['policy' => ['uuid' => 'u-2', 'description' => 'm']])->json(['policy' => ['uuid' => 'u-3', 'description' => 'd']]);
        $made = $pending->confirm();
        self::assertSame(['u-2', 'u-3'], array_map(static fn ($p): string => $p->uuid, $made));
        self::assertSame(['GET /v2/monitoring/alerts', 'POST /v2/monitoring/alerts', 'POST /v2/monitoring/alerts'], array_map(static fn (string $l): string => explode('?', $l)[0], $this->http->log()));

        $all = array_map(static fn (array $b): array => ['uuid' => 'x', 'description' => $b['description']], $bodies);
        $this->http->json(['policies' => $all, 'links' => []]);
        self::assertTrue($this->do()->monitoring()->apply($bodies)->isNoop());
    }

    public function test_delete_policy_is_destructive(): void
    {
        self::assertTrue($this->do()->monitoring()->delete('0b5a3f36-0000-4000-8000-000000000001')->isDestructive());
    }
}
