<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Ploi\Ploi;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class PloiTest extends TestCase
{
    private function ploi(): Ploi
    {
        return Ploi::make('ploi-token-abcdef', $this->options());
    }

    public function test_fluent_server_sites_chain(): void
    {
        $this->http
            ->json(['data' => [['id' => 34, 'server_id' => 12, 'domain' => 'app.example.com', 'status' => 'active', 'project_type' => 'laravel', 'php_version' => '8.4']], 'meta' => ['current_page' => 1, 'last_page' => 2]])
            ->json(['data' => [['id' => 35, 'server_id' => 12, 'domain' => 'api.example.com']], 'meta' => ['current_page' => 2, 'last_page' => 2]]);

        $sites = $this->ploi()->servers()->find(12)->sites()->list();

        self::assertSame(['app.example.com', 'api.example.com'], array_map(static fn ($s): string => $s->domain, $sites));
        self::assertSame(['GET /api/servers/12/sites?per_page=50', 'GET /api/servers/12/sites?page=2&per_page=50'], $this->http->log());
    }

    public function test_find_is_lazy_and_get_fetches(): void
    {
        $server = $this->ploi()->servers()->find('12');
        self::assertSame([], $this->http->requests);

        $this->http->json(['data' => ['id' => 12, 'name' => 'web-01', 'ip_address' => '203.0.113.9', 'internal_ip' => '10.0.0.5', 'sites_count' => 3]]);
        self::assertSame('10.0.0.5', $server->get()->internalIp);
    }

    public function test_deploy_needs_confirmation(): void
    {
        $pending = $this->ploi()->servers()->find(12)->sites()->deploy(34);
        self::assertSame('/servers/12/sites/34/deploy', $pending->plan()['path']);
        self::assertSame([], $this->http->requests);

        $this->http->json(['message' => 'Deployment queued']);
        self::assertTrue($pending->confirm());
        self::assertSame(['POST /api/servers/12/sites/34/deploy'], $this->http->log());
    }

    public function test_rejects_bad_ids(): void
    {
        $this->expectException(ValidationException::class);
        $this->ploi()->servers()->find('12; rm -rf /');
    }
}
