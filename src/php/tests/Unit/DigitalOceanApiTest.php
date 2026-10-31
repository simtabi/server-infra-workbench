<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\VpsServerWorkbench\DigitalOcean\FirewallPreset;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

/** Firewalls, uptime checks/alerts and droplet create. All mocked. */
final class DigitalOceanApiTest extends TestCase
{
    private function do(): DigitalOcean
    {
        return DigitalOcean::make(self::token(), $this->options());
    }

    /**
     * @param array<string, mixed> $body
     * @return list<array{protocol: string, ports: string, addresses: list<string>}>
     */
    private static function rules(array $body): array
    {
        $out = [];
        foreach (is_array($body['inbound_rules'] ?? null) ? $body['inbound_rules'] : [] as $rule) {
            self::assertIsArray($rule);
            $sources = is_array($rule['sources'] ?? null) ? $rule['sources'] : [];
            $addresses = is_array($sources['addresses'] ?? null) ? array_values(array_filter($sources['addresses'], is_string(...))) : [];
            $out[] = ['protocol' => is_string($rule['protocol'] ?? null) ? $rule['protocol'] : '', 'ports' => is_string($rule['ports'] ?? null) ? $rule['ports'] : 'icmp', 'addresses' => $addresses];
        }

        return $out;
    }

    public function test_db_preset_limits_db_ports_and_icmp_to_the_vpc(): void
    {
        $body = FirewallPreset::build('db', 'db-fw', '10.0.0.0/20', ['198.51.100.7/32'], [5432, 6432], [11]);
        $rules = self::rules($body);
        self::assertSame(['198.51.100.7/32'], $rules[0]['addresses']);
        self::assertSame(['22', '5432', '6432', 'icmp'], array_column($rules, 'ports'));
        foreach (array_slice($rules, 1) as $rule) {
            self::assertSame(['10.0.0.0/20'], $rule['addresses']);
        }
        self::assertSame([11], $body['droplet_ids']);
    }

    public function test_web_preset_and_ssh_default_and_validation(): void
    {
        $body = FirewallPreset::build('web', 'web-fw', '10.0.0.0/20', tags: ['web']);
        $rules = self::rules($body);
        self::assertSame(['0.0.0.0/0', '::/0'], $rules[0]['addresses']);
        self::assertSame(['22', '80', '443', 'icmp'], array_column($rules, 'ports'));
        foreach ([['mail', 'x', '10.0.0.0/20', []], ['db', 'x', '10.0.0.0/99', [1]], ['db', 'x', '10.0.0.0/20', []]] as [$role, $name, $cidr, $ids]) {
            try {
                FirewallPreset::build($role, $name, $cidr, [], FirewallPreset::DB_PORTS, $ids);
                self::fail("{$role} {$cidr}");
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function test_apply_creates_updates_or_does_nothing(): void
    {
        $body = FirewallPreset::build('db', 'db-fw', '10.0.0.0/20', [], [5432], [11]);
        $this->http->json(['firewalls' => [], 'links' => []])->json(['firewall' => ['id' => 'fw-1', 'name' => 'db-fw', 'status' => 'waiting']], 202);
        $create = $this->do()->firewalls()->apply($body);
        self::assertSame('POST', $create->plan()['method']);
        self::assertSame('fw-1', $create->confirm()->id);

        $existing = ['id' => 'fw-1', 'name' => 'db-fw', 'status' => 'succeeded', 'inbound_rules' => $body['inbound_rules'], 'outbound_rules' => $body['outbound_rules'], 'droplet_ids' => [11], 'tags' => []];
        $this->http->json(['firewalls' => [$existing], 'links' => []]);
        self::assertTrue($this->do()->firewalls()->apply($body)->isNoop());

        $changed = FirewallPreset::build('db', 'db-fw', '10.0.0.0/20', [], [5432, 6379], [11]);
        $this->http->json(['firewalls' => [$existing], 'links' => []]);
        $update = $this->do()->firewalls()->apply($changed);
        self::assertSame('PUT', $update->plan()['method']);
        self::assertSame('/v2/firewalls/fw-1', $update->plan()['path']);
    }

    public function test_list_flags_world_open_and_delete_is_destructive_and_vpc_lookup(): void
    {
        $this->http->json(['firewalls' => [['id' => 'a', 'name' => 'open', 'inbound_rules' => [['protocol' => 'tcp', 'ports' => '5432', 'sources' => ['addresses' => ['0.0.0.0/0']]]]],
            ['id' => 'b', 'name' => 'web', 'inbound_rules' => [['protocol' => 'tcp', 'ports' => '443', 'sources' => ['addresses' => ['0.0.0.0/0']]]]]], 'links' => []]);
        $list = $this->do()->firewalls()->list();
        self::assertTrue($list[0]->openToWorld);
        self::assertFalse($list[1]->openToWorld);
        self::assertTrue($this->do()->firewalls()->delete('a')->isDestructive());
        $this->http->json(['vpc' => ['id' => 'v', 'ip_range' => '10.0.0.0/20']]);
        self::assertSame('10.0.0.0/20', $this->do()->firewalls()->vpcCidr('v'));
    }

    public function test_uptime_check_create_is_idempotent_and_validates(): void
    {
        $this->http->json(['checks' => [], 'links' => []])->json(['check' => ['id' => 'c1', 'name' => 'app', 'type' => 'https', 'target' => 'https://app.example.com/up', 'regions' => ['us_east'], 'enabled' => true]], 201);
        $create = $this->do()->uptime()->createCheck('app', 'https://app.example.com/up', 'https', ['us_east']);
        self::assertSame(['name' => 'app', 'type' => 'https', 'target' => 'https://app.example.com/up', 'regions' => ['us_east'], 'enabled' => true], $create->plan()['payload']);
        self::assertSame('c1', $create->confirm()->id);

        $this->http->json(['checks' => [['id' => 'c1', 'name' => 'app', 'type' => 'https', 'target' => 'https://app.example.com/up']], 'links' => []]);
        self::assertTrue($this->do()->uptime()->createCheck('app', 'https://app.example.com/up')->isNoop());

        foreach ([['x', 'http://a.example.com', 'https', ['us_east']], ['x', 'https://a.example.com', 'https', ['mars']], ['x', 'a.example.com', 'smtp', ['us_east']]] as [$n, $t, $type, $regions]) {
            try {
                $this->http->json(['checks' => [], 'links' => []]);
                $this->do()->uptime()->createCheck($n, $t, $type, $regions);
                self::fail("{$t} {$type}");
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function test_uptime_alerts_defaults_and_validation(): void
    {
        $alert = $this->do()->uptime()->createAlert('c1', 'latency', ['ops@example.com']);
        self::assertSame(2000, $alert->plan()['payload']['threshold']);
        self::assertSame('greater_than', $alert->plan()['payload']['comparison']);
        $ssl = $this->do()->uptime()->createAlert('c1', 'ssl_expiry', ['ops@example.com'], 0, '1h');
        self::assertSame(14, $ssl->plan()['payload']['threshold']);
        self::assertSame('less_than', $ssl->plan()['payload']['comparison']);
        $this->http->json(['alert' => ['id' => 'al1', 'name' => 'down alert', 'type' => 'down', 'notifications' => ['email' => ['ops@example.com']]]], 201);
        self::assertSame('al1', $this->do()->uptime()->createAlert('c1', 'down', ['ops@example.com'])->confirm()->id);
        self::assertSame('POST /v2/uptime/checks/c1/alerts', $this->http->log()[0]);
        foreach ([['c1', 'sms', ['ops@example.com'], '2m'], ['c1', 'down', [], '2m'], ['c1', 'down', ['not-an-email'], '2m'], ['c1', 'down', ['ops@example.com'], '7m']] as [$id, $type, $emails, $period]) {
            try {
                $this->do()->uptime()->createAlert($id, $type, $emails, 0, $period);
                self::fail($type);
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function test_droplet_create_plan_requires_keys_and_is_idempotent_by_name(): void
    {
        $this->http->json(['droplets' => [], 'links' => []])->json(['droplet' => ['id' => 99, 'name' => 'web-02', 'status' => 'new']], 202);
        $create = $this->do()->droplets()->create('web-02', 'nyc3', 's-2vcpu-4gb', 'ubuntu-24-04-x64', ['123', 'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99'], 'vpc-uuid-1', ['web'], false, "#cloud-config\n");
        $plan = $create->plan();
        self::assertSame([123, 'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99'], $plan['payload']['ssh_keys']);
        self::assertSame('vpc-uuid-1', $plan['payload']['vpc_uuid']);
        self::assertTrue($plan['payload']['monitoring']);
        self::assertStringContainsString('billed hourly', (string) $plan['note']);
        self::assertSame(['GET /v2/droplets?per_page=200&name=web-02'], $this->http->log(), 'dry run sends no POST');
        self::assertSame(99, $create->confirm()->id);
        self::assertSame('web-02', MockHttpClient::body($this->http->last())['name']);

        $this->http->json(['droplets' => [['id' => 5, 'name' => 'web-02']], 'links' => []]);
        self::assertTrue($this->do()->droplets()->create('web-02', 'nyc3', 's-1vcpu-1gb', 'ubuntu-24-04-x64', [1])->isNoop());

        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage('without an SSH key');
        $this->do()->droplets()->create('web-03', 'nyc3', 's-1vcpu-1gb', 'ubuntu-24-04-x64', []);
    }
}
