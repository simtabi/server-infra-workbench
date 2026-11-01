<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Unit;

use Simtabi\ServerInfraWorkbench\Cloudflare\Cloudflare;
use Simtabi\ServerInfraWorkbench\Cloudflare\OriginCertificates;
use Simtabi\ServerInfraWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Gcp\Auth\StaticTokenProvider;
use Simtabi\ServerInfraWorkbench\Gcp\Gcp;
use Simtabi\ServerInfraWorkbench\Ploi\Crontabs;
use Simtabi\ServerInfraWorkbench\Ploi\Ploi;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Security\IssuedCredential;
use Simtabi\ServerInfraWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\ServerInfraWorkbench\Tests\TestCase;

/** The resources added in the provider audit: safety rules, request shapes and one-time secrets. No network. */
final class ProviderResourcesTest extends TestCase
{
    private const string ZONE_ID = '0123456789abcdef0123456789abcdef';

    private function do(): DigitalOcean
    {
        return DigitalOcean::make(self::token(), $this->options());
    }

    private function cf(): Cloudflare
    {
        return Cloudflare::make(self::fake('cf'), $this->options());
    }

    private function gcp(): Gcp
    {
        return Gcp::make('proj-123', new StaticTokenProvider('ya29'.'.static'), $this->options(), new Credentials(null, []));
    }

    private function zone(): void
    {
        $this->http->json(['success' => true, 'result' => ['id' => self::ZONE_ID, 'name' => 'example.com', 'status' => 'active', 'plan' => ['name' => 'Free']]]);
    }

    private function expectInvalid(\Closure $call, string $why): void
    {
        try {
            $call();
            self::fail('accepted: '.$why);
        } catch (ValidationException) {
            $this->addToAssertionCount(1);
        }
    }

    // --- DigitalOcean ---

    public function test_do_default_vpc_and_vpc_with_members_are_never_deleted(): void
    {
        $this->http->json(['vpc' => ['id' => 'v1', 'name' => 'default-nyc3', 'region' => 'nyc3', 'ip_range' => '10.108.0.0/20', 'default' => true]]);
        $this->expectInvalid(fn () => $this->do()->vpcs()->delete('v1'), 'default vpc');

        $this->http->json(['vpc' => ['id' => 'v2', 'name' => 'app', 'region' => 'nyc3', 'default' => false]])
            ->json(['members' => [['urn' => 'do:droplet:1', 'name' => 'web-1']], 'links' => []]);
        $this->expectInvalid(fn () => $this->do()->vpcs()->delete('v2'), 'vpc with members');

        $this->http->json(['vpc' => ['id' => 'v3', 'name' => 'old', 'region' => 'nyc3', 'default' => false]])->json(['members' => [], 'links' => []]);
        $delete = $this->do()->vpcs()->delete('v3');
        self::assertTrue($delete->isDestructive());
        self::assertSame(['GET /v2/vpcs/v1', 'GET /v2/vpcs/v2', 'GET /v2/vpcs/v2/members?per_page=200', 'GET /v2/vpcs/v3', 'GET /v2/vpcs/v3/members?per_page=200'], $this->http->log());

        $this->http->json(['vpc' => ['id' => 'v1', 'name' => 'default-nyc3', 'region' => 'nyc3', 'default' => true]]);
        self::assertTrue($this->do()->vpcs()->setDefault('v1')->isNoop());
    }

    public function test_do_volumes_only_grow_and_growing_is_destructive(): void
    {
        $volume = ['volume' => ['id' => 'vol-1', 'name' => 'data', 'region' => ['slug' => 'nyc3'], 'size_gigabytes' => 100, 'droplet_ids' => []]];
        $this->http->json($volume);
        $this->expectInvalid(fn () => $this->do()->volumes()->resize('vol-1', 50), 'shrink');
        $this->http->json($volume);
        $grow = $this->do()->volumes()->resize('vol-1', 200);
        self::assertTrue($grow->isDestructive());
        self::assertSame(['type' => 'resize', 'size_gigabytes' => 200, 'region' => 'nyc3'], $grow->plan()['payload']);
    }

    public function test_do_spaces_key_secret_is_issued_once_and_never_serialised(): void
    {
        $secret = self::secret('sk-');
        $this->expectInvalid(fn () => $this->do()->spacesKeys()->create('ci', []), 'no buckets without fullaccess');
        $this->expectInvalid(fn () => $this->do()->spacesKeys()->create('ci', ['b1'], 'fullaccess'), 'fullaccess with buckets');

        $this->http->json(['keys' => [], 'links' => []])
            ->json(['key' => ['name' => 'ci', 'access_key' => 'AK'.bin2hex(random_bytes(8)), 'secret_key' => $secret, 'grants' => [['bucket' => 'assets', 'permission' => 'read']]]], 201);
        $action = $this->do()->spacesKeys()->create('ci', ['assets'], 'read');
        self::assertFalse($action->isDestructive());
        self::assertSame(['name' => 'ci', 'grants' => [['bucket' => 'assets', 'permission' => 'read']]], $action->plan()['payload']);
        $issued = $action->confirm();
        self::assertInstanceOf(IssuedCredential::class, $issued);
        self::assertSame($secret, $issued->secret->reveal());
        self::assertStringNotContainsString($secret, json_encode($issued, JSON_THROW_ON_ERROR).print_r($issued, true).var_export($issued->item->data, true));

        $this->http->json(['keys' => [], 'links' => []]);
        self::assertTrue($this->do()->spacesKeys()->create('all', [], 'fullaccess')->isDestructive());
    }

    public function test_do_dns_upsert_qualifies_hostnames_and_reserved_ip_assign(): void
    {
        $this->http->json(['domain_records' => [], 'links' => []]);
        $cname = $this->do()->domains()->records('example.com')->upsert('CNAME', 'www', 'example.com');
        self::assertSame('example.com.', $cname->plan()['payload']['data']);

        $this->http->json(['domain_records' => [['id' => 5, 'type' => 'A', 'name' => 'app', 'data' => '203.0.113.7', 'ttl' => 1800]], 'links' => []]);
        self::assertTrue($this->do()->domains()->records('example.com')->upsert('A', 'app', '203.0.113.7')->isNoop());

        $assign = $this->do()->reservedIps()->assign('203.0.113.9', 42);
        self::assertSame(['type' => 'assign', 'droplet_id' => 42], $assign->plan()['payload']);
        self::assertTrue($this->do()->reservedIps()->delete('203.0.113.9')->isDestructive());
    }

    // --- Cloudflare ---

    public function test_cf_weakening_ssl_is_destructive_and_same_value_is_a_noop(): void
    {
        $this->zone();
        $this->http->json(['success' => true, 'result' => ['id' => 'ssl', 'value' => 'strict']]);
        $weaken = $this->cf()->zones()->settings(self::ZONE_ID)->set('ssl', 'flexible');
        self::assertTrue($weaken->isDestructive());
        self::assertSame('PATCH', $weaken->plan()['method']);

        $this->zone();
        $this->http->json(['success' => true, 'result' => ['id' => 'ssl', 'value' => 'full']]);
        self::assertFalse($this->cf()->zones()->settings(self::ZONE_ID)->set('ssl', 'strict')->isDestructive());

        $this->zone();
        $this->http->json(['success' => true, 'result' => ['id' => 'ssl', 'value' => 'strict']]);
        self::assertTrue($this->cf()->zones()->settings(self::ZONE_ID)->set('ssl', 'strict')->isNoop());

        $this->zone();
        $this->expectInvalid(fn () => $this->cf()->zones()->settings(self::ZONE_ID)->set('development_mode', 'on'), 'setting outside the allowlist');
    }

    public function test_cf_purge_limits_and_purge_everything_is_destructive(): void
    {
        $this->zone();
        $cache = $this->cf()->zones()->cache(self::ZONE_ID);
        $this->expectInvalid(fn () => $cache->purgeFiles(['https://evil.example.net/x']), 'URL outside the zone');
        $this->expectInvalid(fn () => $cache->purgeFiles(array_fill(0, 31, 'https://example.com/a')), 'more than 30');
        self::assertFalse($cache->purgeFiles(['https://cdn.example.com/app.css'])->isDestructive());
        self::assertTrue($cache->purgeEverything()->isDestructive());
    }

    public function test_cf_origin_certificate_key_is_generated_locally(): void
    {
        [$key, $csr] = OriginCertificates::keyAndCsr('example.com');
        self::assertStringContainsString('BEGIN PRIVATE KEY', $key->reveal());
        self::assertStringContainsString('BEGIN CERTIFICATE REQUEST', $csr);
        self::assertSame('***', (string) $key);

        $this->zone();
        $certs = $this->cf()->zones()->originCertificates(self::ZONE_ID);
        $this->expectInvalid(fn () => $certs->create(['other.example.org']), 'hostname outside the zone');
        $this->http->json(['success' => true, 'result' => ['id' => 'c1', 'hostnames' => ['example.com'], 'certificate' => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", 'expires_on' => '2041-01-01']]);
        $issued = $certs->create(['example.com', '*.example.com'], 90)->confirm();
        $sent = MockHttpClient::body($this->http->last());
        self::assertIsString($sent['csr']);
        self::assertStringContainsString('BEGIN CERTIFICATE REQUEST', $sent['csr']);
        self::assertStringNotContainsString('PRIVATE KEY', (string) $this->http->last()->getBody());
        self::assertStringContainsString('BEGIN PRIVATE KEY', $issued->secret->reveal());
    }

    // --- Google Cloud ---

    public function test_gcp_world_open_firewall_needs_force_only_for_non_web_ports(): void
    {
        $this->http->json(['items' => []]);
        self::assertFalse($this->gcp()->firewalls()->create('web', ['tcp:80,443'], ['0.0.0.0/0'])->isDestructive());
        $this->http->json(['items' => []]);
        $ssh = $this->gcp()->firewalls()->create('ssh', ['tcp:22'], ['0.0.0.0/0'], ['bastion']);
        self::assertTrue($ssh->isDestructive());
        self::assertSame([['IPProtocol' => 'tcp', 'ports' => ['22']]], $ssh->plan()['payload']['allowed']);
        $this->expectInvalid(fn () => $this->gcp()->firewalls()->create('bad', ['tcp:22;rm'], ['10.0.0.0/8']), 'bad protocol spec');
    }

    public function test_gcp_dns_upsert_is_one_atomic_change(): void
    {
        $zones = ['managedZones' => [['name' => 'example-com', 'dnsName' => 'example.com.', 'visibility' => 'public']]];
        $this->http->json($zones)->json($zones)->json(['rrsets' => [['name' => 'app.example.com.', 'type' => 'A', 'ttl' => 300, 'rrdatas' => ['203.0.113.7']]]]);
        $change = $this->gcp()->dns()->upsert('example.com', 'A', 'app', ['203.0.113.8']);
        self::assertSame([
            'additions' => [['name' => 'app.example.com.', 'type' => 'A', 'ttl' => 300, 'rrdatas' => ['203.0.113.8']]],
            'deletions' => [['name' => 'app.example.com.', 'type' => 'A', 'ttl' => 300, 'rrdatas' => ['203.0.113.7']]],
        ], $change->plan()['payload']);
        self::assertStringEndsWith('/managedZones/example-com/changes', $change->plan()['path']);

        $this->http->json($zones);
        $this->expectInvalid(fn () => $this->gcp()->dns()->upsert('example.com', 'A', 'app.example.org.', ['203.0.113.8']), 'name outside the zone');
    }

    public function test_gcp_bucket_is_private_by_construction(): void
    {
        $this->http->json(['items' => []]);
        $create = $this->gcp()->storage()->create('acme-backups-'.bin2hex(random_bytes(3)), 'us-east1', 'nearline', 30);
        $body = json_encode($create->plan()['payload'], JSON_THROW_ON_ERROR);
        self::assertStringContainsString('"iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true},"publicAccessPrevention":"enforced"}', $body);
        self::assertStringContainsString('"storageClass":"NEARLINE"', $body);
        self::assertStringContainsString('"condition":{"age":30}', $body);
        $this->http->json(['name' => 'x', 'location' => 'US-EAST1']);
        $create->confirm();
        self::assertStringContainsString('/storage/v1/b?project=proj-123', (string) $this->http->last()->getUri());
    }

    // --- Ploi ---

    public function test_ploi_cron_database_and_certificate(): void
    {
        $server = Ploi::make(self::fake('ploi'), $this->options())->servers()->find(12);
        self::assertSame('@daily', Crontabs::frequency('@daily'));
        $this->expectInvalid(fn () => Crontabs::frequency('every day'), 'bad schedule');

        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        self::assertSame(['command' => 'php artisan schedule:run', 'frequency' => '* * * * *', 'user' => 'ploi'], $server->crontabs()->create('php artisan schedule:run', '*  * * * *')->plan()['payload']);

        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]])
            ->json(['data' => ['id' => 3, 'name' => 'app', 'type' => 'mysql', 'status' => 'creating']], 201);
        $db = $server->databases()->create('app', 'app_user');
        self::assertSame('***', $db->plan()['payload']['password'], 'the plan never shows a password, not even a placeholder from the API');
        $issued = $db->confirm();
        self::assertInstanceOf(IssuedCredential::class, $issued);
        $sent = MockHttpClient::body($this->http->last());
        self::assertSame($issued->secret->reveal(), $sent['password']);
        self::assertGreaterThanOrEqual(32, strlen($issued->secret->reveal()));

        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]])->json(['data' => ['id' => 4, 'name' => 'logs']], 201);
        $plain = $server->databases()->create('logs')->confirm();
        self::assertNotInstanceOf(IssuedCredential::class, $plain, 'no user, no password, nothing secret to save');
        self::assertSame(4, $plain->int('id'));

        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        $cert = $server->certificates(40)->create(['app.example.com', 'www.app.example.com']);
        self::assertSame(['certificate' => 'app.example.com,www.app.example.com', 'type' => 'letsencrypt', 'force' => false], $cert->plan()['payload']);
        self::assertTrue($server->restart()->isDestructive());
    }
}
