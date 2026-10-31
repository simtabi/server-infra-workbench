<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use GuzzleHttp\Psr7\Response;
use Simtabi\VpsServerWorkbench\Console\Application;
use Simtabi\VpsServerWorkbench\Console\Output;
use Simtabi\VpsServerWorkbench\Console\ProviderFactory;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\FakeKeys;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\FakeSshRunner;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

/** CLI wiring for firewalls, uptime, droplet-create, ploi sites/daemons/scripts, health and keys. */
final class ConsoleNewCommandsTest extends TestCase
{
    /** @var resource */
    private $stdout;

    /** @var resource */
    private $stderr;

    private FakeSshRunner $ssh;

    private bool $answer = true;

    /** @var list<string> */
    private array $answers = [];

    protected function setUp(): void
    {
        parent::setUp();
        $this->ssh = new FakeSshRunner;
    }

    private function app(): Application
    {
        $this->stdout = self::memory();
        $this->stderr = self::memory();
        $env = ['DIGITALOCEAN_TOKEN' => 'do-token-abcdef', 'PLOI_API_TOKEN' => 'ploi-token-abcdef', 'HCLOUD_TOKEN' => 'hcloud-token-abcdef'];

        return new Application(
            new ProviderFactory($this->options(), new Credentials('/nonexistent/credentials', $env), null, $this->ssh, [], '/tmp'),
            new Output($this->stdout, $this->stderr),
            fn (string $d): bool => $this->answer,
            function (string $q): ?string {
                return array_shift($this->answers);
            },
        );
    }

    /** @return resource */
    private static function memory()
    {
        $stream = fopen('php://memory', 'w+');
        self::assertIsResource($stream);

        return $stream;
    }

    private function out(): string
    {
        rewind($this->stdout);

        return (string) stream_get_contents($this->stdout);
    }

    private function err(): string
    {
        rewind($this->stderr);

        return (string) stream_get_contents($this->stderr);
    }

    public function test_firewall_apply_dry_run_with_cidr_sends_only_the_lookup(): void
    {
        $this->http->json(['firewalls' => [], 'links' => []]);
        self::assertSame(0, $this->app()->run(['do', 'firewall-apply', 'db', '--vpc', '10.0.0.0/20', '--droplet', '11,12', '--ports', '5432,6432', '--ssh-from', '198.51.100.7/32', '--dry-run']));
        self::assertStringContainsString('DRY RUN', $this->out());
        self::assertStringContainsString('"workbench-db"', $this->out());
        self::assertSame(['GET /v2/firewalls?per_page=200'], $this->http->log());
    }

    public function test_firewall_apply_looks_up_a_vpc_id(): void
    {
        $this->http->json(['vpc' => ['ip_range' => '10.0.0.0/20']])->json(['firewalls' => [], 'links' => []]);
        self::assertSame(0, $this->app()->run(['do', 'firewall-apply', 'web', '--vpc', 'vpc-1', '--tag', 'web', '--dry-run', '--json']));
        self::assertSame('GET /v2/vpcs/vpc-1', $this->http->log()[0]);
        self::assertStringContainsString('"dryRun":true', str_replace(' ', '', $this->out()));
    }

    public function test_firewall_delete_needs_force_and_bad_role_is_usage(): void
    {
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['do', 'firewall-delete', 'fw-1', '--yes']));
        self::assertSame(Application::USAGE, $this->app()->run(['do', 'firewall-apply', 'mail', '--vpc', '10.0.0.0/20', '--tag', 'x']));
        self::assertSame([], $this->http->requests);
    }

    public function test_resize_and_alert_commands(): void
    {
        $droplet = ['droplet' => ['id' => 7, 'name' => 'db-1', 'status' => 'active', 'region' => ['slug' => 'nyc3'], 'size_slug' => 's-1vcpu-2gb', 'memory' => 2048, 'vcpus' => 1, 'disk' => 50, 'networks' => ['v4' => []], 'tags' => [], 'created_at' => '2026-01-01T00:00:00Z']];
        $this->http->json($droplet);
        self::assertSame(0, $this->app()->run(['do', 'resize', '7', '--size', 's-2vcpu-4gb', '--dry-run']));
        self::assertStringContainsString('s-1vcpu-2gb -> s-2vcpu-4gb', $this->out());
        self::assertSame(Application::USAGE, $this->app()->run(['do', 'resize', '7']));
        $this->http->json($droplet);
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['do', 'resize', '7', '--size', 's-2vcpu-4gb', '--disk', '--yes']));
        self::assertSame(['GET /v2/droplets/7', 'GET /v2/droplets/7'], $this->http->log());

        $this->http->json(['policies' => [], 'links' => []]);
        self::assertSame(0, $this->app()->run(['do', 'alerts', 'standard', '--email', 'ops@example.com', '--tag', 'db', '--dry-run']));
        self::assertStringContainsString('3 new of 3', $this->out());
        self::assertSame(Application::USAGE, $this->app()->run(['do', 'alerts', 'standard', '--tag', 'db']));
    }

    public function test_uptime_commands(): void
    {
        $this->http->json(['checks' => [['id' => 'c1', 'name' => 'app', 'type' => 'https', 'target' => 'https://app.example.com/up']], 'links' => []]);
        self::assertSame(0, $this->app()->run(['do', 'uptime']));
        self::assertStringContainsString('https://app.example.com/up', $this->out());

        $this->http->json(['checks' => [], 'links' => []]);
        self::assertSame(0, $this->app()->run(['do', 'uptime', 'check-create', 'app', 'https://app.example.com/up', '--regions', 'us_east,eu_west', '--dry-run']));
        self::assertStringContainsString('"regions":["us_east","eu_west"]', $this->out());

        self::assertSame(0, $this->app()->run(['do', 'uptime', 'alert-create', 'c1', 'down', '--email', 'ops@example.com', '--dry-run']));
        self::assertSame(Application::USAGE, $this->app()->run(['do', 'uptime', 'alert-create', 'c1', 'down', '--dry-run']));
    }

    public function test_droplet_create_requires_region_size_and_keys_and_reads_user_data(): void
    {
        self::assertSame(Application::USAGE, $this->app()->run(['do', 'droplet-create', 'web-02', '--size', 's-1vcpu-1gb', '--ssh-keys', '1']));
        $file = $this->tempDir().'/cloud-init.yml';
        file_put_contents($file, "#cloud-config\npackages: [jq]\n");
        $this->http->json(['droplets' => [], 'links' => []]);
        self::assertSame(0, $this->app()->run(['do', 'droplet-create', 'web-02', '--region', 'nyc3', '--size', 's-1vcpu-1gb', '--ssh-keys', '1,2', '--tag', 'web', '--backups', '--user-data', $file, '--dry-run']));
        self::assertStringContainsString('"backups":true', $this->out());
        self::assertStringContainsString('packages: [jq]', $this->out());
    }

    public function test_ploi_new_commands(): void
    {
        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        self::assertSame(0, $this->app()->run(['ploi', 'site-create', '12', 'app.example.com', '--project-type', 'laravel', '--dry-run']));
        self::assertStringContainsString('"root_domain":"app.example.com"', $this->out());

        $this->http->json(['deploy_script' => "git pull\n"]);
        self::assertSame(0, $this->app()->run(['ploi', 'deploy-script', '12', '40']));
        self::assertStringContainsString('git pull', $this->out());

        $file = $this->tempDir().'/deploy.sh';
        file_put_contents($file, "git pull\nphp artisan migrate --force\n");
        $this->http->json(['deploy_script' => "git pull\n"])->push(new Response(200, [], '{}'));
        self::assertSame(0, $this->app()->run(['ploi', 'deploy-script-set', '12', '40', '--file', $file, '--yes']));
        self::assertStringContainsString('deploy script saved', $this->out());

        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        self::assertSame(0, $this->app()->run(['ploi', 'daemon-create', '12', '--command', 'php artisan queue:work', '--processes', '2', '--dry-run']));
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['ploi', 'daemon-delete', '12', '4', '--yes']));
        self::assertSame(Application::USAGE, $this->app()->run(['ploi', 'deploy-script-set', '12', '40']));
    }

    public function test_health_exit_codes(): void
    {
        $this->http->push(new Response(200, [], 'ok'))->push(new Response(500));
        self::assertSame(Application::FAILED, $this->app()->run(['health', 'https://a.example.com/up', 'https://b.example.com/up']));
        self::assertStringContainsString('FAIL', $this->out());
        $this->http->push(new Response(200, [], 'ok'));
        self::assertSame(0, $this->app()->run(['health', 'https://a.example.com/up', '--contains', 'ok', '--json']));
        self::assertSame(Application::USAGE, $this->app()->run(['health']));
    }

    public function test_keys_providers_and_account_list(): void
    {
        self::assertSame(0, $this->app()->run(['keys', 'providers', '--config', '/nonexistent/keys.json']));
        self::assertMatchesRegularExpression('/hetzner\s+yes/', $this->out());
        self::assertStringNotContainsString('hcloud-token-abcdef', $this->out());

        $this->http->json(['ssh_keys' => [['id' => 1, 'name' => 'lap', 'fingerprint' => 'aa:bb']], 'meta' => ['pagination' => ['next_page' => null]]]);
        self::assertSame(0, $this->app()->run(['keys', 'account', 'list', '--provider', 'hetzner', '--config', '/nonexistent/keys.json']));
        self::assertStringContainsString('lap', $this->out());
        self::assertSame(Application::USAGE, $this->app()->run(['keys', 'account', 'list']));
        self::assertSame(Application::CREDENTIALS, $this->app()->run(['keys', 'account', 'list', '--provider', 'vultr', '--config', '/nonexistent/keys.json']));
    }

    public function test_keys_account_add_reads_only_pub_files(): void
    {
        $dir = $this->tempDir();
        file_put_contents($dir.'/id_test.pub', FakeKeys::ed25519('me@laptop')."\n");
        file_put_contents($dir.'/id_test', '-----BEGIN OPENSSH '."PRIVATE KEY-----\nxx\n");
        self::assertSame(Application::USAGE, $this->app()->run(['keys', 'account', 'add', '--provider', 'hetzner', '--name', 'lap', '--key-file', $dir.'/id_test', '--config', '/nonexistent/k.json']));
        self::assertStringContainsString('private keys are never read', $this->err());
        self::assertStringNotContainsString('BEGIN', $this->err());

        $this->http->json(['ssh_keys' => [], 'meta' => ['pagination' => ['next_page' => null]]]);
        self::assertSame(0, $this->app()->run(['keys', 'account', 'add', '--provider', 'hetzner', '--name', 'lap', '--key-file', $dir.'/id_test.pub', '--dry-run', '--config', '/nonexistent/k.json']));
        self::assertStringContainsString('ssh-ed25519', $this->out());
    }

    public function test_keys_account_remove_needs_force(): void
    {
        $this->http->json(['ssh_keys' => [['id' => 1, 'name' => 'lap']], 'meta' => ['pagination' => ['next_page' => null]]]);
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['keys', 'account', 'remove', '1', '--provider', 'hetzner', '--yes', '--config', '/nonexistent/k.json']));
        self::assertStringContainsString('destructive', $this->err());
    }

    public function test_keys_server_list_add_remove(): void
    {
        $mine = FakeKeys::ed25519('me@laptop', 1);
        $other = FakeKeys::ed25519('ci@runner', 2);
        $this->ssh->file = "{$mine}\n{$other}\n";
        $this->ssh->sessionFingerprint = FakeKeys::fingerprint($mine);
        self::assertSame(0, $this->app()->run(['keys', 'server', 'list', '--host', 'root@db-01', '--ssh-opt', '-p 2222']));
        self::assertStringContainsString('ci@runner', $this->out());
        self::assertStringContainsString("can't be removed", $this->out());
        self::assertSame(['-p', '2222'], array_slice($this->ssh->calls[0]['options'], 0, 2));

        self::assertSame(Application::USAGE, $this->app()->run(['keys', 'server', 'remove', '1', '--host', 'root@db-01', '--yes', '--force']));
        self::assertSame(0, $this->app()->run(['keys', 'server', 'remove', 'ci@runner', '--host', 'root@db-01', '--yes']));
        self::assertSame("{$mine}\n", $this->ssh->file);

        self::assertSame(0, $this->app()->run(['keys', 'server', 'add', '--host', 'root@db-01', '--public-key', $other, '--yes']));
        self::assertStringContainsString('key added', $this->out());
        self::assertSame(0, $this->app()->run(['keys', 'server', 'add', '--host', 'root@db-01', '--public-key', $other, '--yes']));
        self::assertStringContainsString('already there', $this->out());
    }

    public function test_keys_fingerprint(): void
    {
        $key = FakeKeys::ed25519('me@laptop');
        self::assertSame(0, $this->app()->run(['keys', 'fingerprint', '--public-key', $key]));
        self::assertStringContainsString(FakeKeys::fingerprint($key), $this->out());
    }

    public function test_interactive_menu_server_remove_with_force_prompt(): void
    {
        $mine = FakeKeys::ed25519('me@laptop', 1);
        $other = FakeKeys::ed25519('ci@runner', 2);
        $this->ssh->file = "{$mine}\n{$other}\n";
        $this->ssh->sessionFingerprint = null; // unknown session key: the menu asks for "force"
        $this->answers = ['2', 'root@db-01', '3', '2', 'force', 'yes', 'b', 'q'];
        self::assertSame(0, $this->app()->run(['keys']));
        self::assertSame("{$mine}\n", $this->ssh->file);
        self::assertStringContainsString('could not tell which key', $this->err());
        self::assertStringContainsString('done: ssh: remove authorized key', $this->out());
    }

    public function test_interactive_menu_cancel_and_eof(): void
    {
        $mine = FakeKeys::ed25519('me@laptop', 1);
        $other = FakeKeys::ed25519('ci@runner', 2);
        $this->ssh->file = "{$mine}\n{$other}\n";
        $this->ssh->sessionFingerprint = FakeKeys::fingerprint($mine);
        $this->answers = ['2', 'root@db-01', '3', '2', 'no'];
        self::assertSame(0, $this->app()->run(['keys']));
        self::assertSame("{$mine}\n{$other}\n", $this->ssh->file);
        self::assertStringContainsString('cancelled; nothing changed', $this->out());

        $this->answers = ['2', 'root@db-01', '3', '1', 'b', 'q'];
        self::assertSame(0, $this->app()->run(['keys']));
        self::assertStringContainsString('current session logged in with', $this->err());
    }

    public function test_interactive_menu_account_add_dry_run(): void
    {
        $this->answers = ['1', 'hetzner', '2', 'lap', FakeKeys::ed25519('me@laptop'), 'b', 'q'];
        $this->http->json(['ssh_keys' => [], 'meta' => ['pagination' => ['next_page' => null]]]);
        self::assertSame(0, $this->app()->run(['keys', '--dry-run', '--config', '/nonexistent/k.json']));
        self::assertStringContainsString('DRY RUN', $this->out());
        self::assertSame(['GET /v1/ssh_keys?per_page=50'], $this->http->log());
    }
}
