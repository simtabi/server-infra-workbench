<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Unit;

use Simtabi\ServerInfraWorkbench\Console\Application;
use Simtabi\ServerInfraWorkbench\Console\Help;
use Simtabi\ServerInfraWorkbench\Console\Output;
use Simtabi\ServerInfraWorkbench\Console\ProviderFactory;
use Simtabi\ServerInfraWorkbench\Gcp\Auth\StaticTokenProvider;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\ServerInfraWorkbench\Tests\TestCase;

/** CLI wiring for the provider areas: --dry-run, confirmation, --force, and one-time secrets kept off stdout. */
final class ConsoleProvidersTest extends TestCase
{
    /** @var resource */
    private $stdout;

    /** @var resource */
    private $stderr;

    private function app(): Application
    {
        $this->stdout = self::memory();
        $this->stderr = self::memory();
        $env = ['DIGITALOCEAN_TOKEN' => self::fake('do'), 'CLOUDFLARE_API_TOKEN' => self::fake('cf'), 'PLOI_API_TOKEN' => self::fake('ploi'),
            'GITHUB_TOKEN' => self::fake('gh'), 'GCP_PROJECT' => 'proj-123'];

        return new Application(
            new ProviderFactory($this->options(), new Credentials('/nonexistent/credentials', $env), new StaticTokenProvider('ya29'.'.static')),
            new Output($this->stdout, $this->stderr),
            static fn (string $d): bool => false,
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
        rewind($this->stderr);

        return stream_get_contents($this->stdout).stream_get_contents($this->stderr);
    }

    /** A directory that is not inside any git checkout (the system temp dir). */
    private function outsideRepo(): string
    {
        $dir = $this->tempDir();
        self::assertNull(Credentials::enclosingRepository($dir.'/x'), 'temp dir must be outside a git checkout');

        return $dir;
    }

    public function test_every_area_has_help_and_unknown_commands_are_usage_errors(): void
    {
        foreach (['do', 'cf', 'gcp', 'github', 'gh', 'ploi'] as $area) {
            self::assertSame(Application::USAGE, $this->app()->run([$area]), $area);
            self::assertStringContainsString('workbench ', $this->out());
            self::assertSame(0, $this->app()->run(['help', $area]), $area);
            self::assertSame(Application::USAGE, $this->app()->run([$area, 'no-such-command']), $area);
        }
        self::assertStringContainsString('workbench github secrets set', Help::for('gh'));
        self::assertSame([], $this->http->requests);
    }

    public function test_spaces_key_secret_goes_to_a_0600_file_and_never_to_stdout(): void
    {
        $secret = self::secret('sk-');
        $file = $this->outsideRepo().'/spaces.key';

        self::assertSame(Application::USAGE, $this->app()->run(['do', 'spaces-keys', 'create', 'ci', '--bucket', 'assets', '--yes']), '--out is required');
        $here = getcwd().'/spaces.key';
        self::assertSame(Application::USAGE, $this->app()->run(['do', 'spaces-keys', 'create', 'ci', '--bucket', 'assets', '--out', $here, '--yes']), 'refuses a path inside the checkout');
        self::assertStringContainsString('git checkout', $this->out());
        self::assertFileDoesNotExist($here);

        $this->http->json(['keys' => [], 'links' => []])
            ->json(['key' => ['name' => 'ci', 'access_key' => 'AK'.bin2hex(random_bytes(8)), 'secret_key' => $secret, 'grants' => []]], 201);
        self::assertSame(0, $this->app()->run(['do', 'spaces-keys', 'create', 'ci', '--bucket', 'assets', '--out', $file, '--yes', '--json']));
        self::assertStringNotContainsString($secret, $this->out());
        self::assertSame($secret, file_get_contents($file));
        self::assertSame(0o600, fileperms($file) & 0o777);
        self::assertSame(['GET /v2/spaces/keys?per_page=200', 'POST /v2/spaces/keys'], $this->http->log());
    }

    public function test_destructive_writes_need_force_and_dry_run_sends_nothing(): void
    {
        $zone = ['success' => true, 'result' => ['id' => '0123456789abcdef0123456789abcdef', 'name' => 'example.com', 'status' => 'active']];
        $this->http->json($zone);
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['cf', 'purge', '0123456789abcdef0123456789abcdef', '--everything', '--yes']));

        $this->http->json(['items' => []]);
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['gcp', 'firewall-create', 'ssh', '--allow', 'tcp:22', '--source-ranges', '0.0.0.0/0', '--yes']));
        $this->http->json(['items' => []]);
        self::assertSame(0, $this->app()->run(['gcp', 'firewall-create', 'ssh', '--allow', 'tcp:22', '--source-ranges', '198.51.100.7/32', '--dry-run']));
        self::assertStringContainsString('DRY RUN', $this->out());

        $this->http->json(['vpc' => ['id' => 'v1', 'name' => 'default-nyc3', 'region' => 'nyc3', 'default' => true]]);
        self::assertSame(Application::USAGE, $this->app()->run(['do', 'vpcs', 'delete', 'v1', '--force']));
        self::assertStringContainsString('vpcs default', $this->out());

        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        self::assertSame(0, $this->app()->run(['ploi', 'cron-create', '12', '--command', 'php artisan schedule:run', '--frequency', '* * * * *', '--dry-run']));
        self::assertSame(['GET'], array_values(array_unique(array_map(static fn ($r): string => $r->getMethod(), $this->http->requests))), 'no writes were sent');
    }

    public function test_github_secret_comes_from_a_file_and_is_sealed(): void
    {
        $pair = sodium_crypto_box_keypair();
        $secret = self::secret('val-');
        $file = $this->outsideRepo().'/value';
        file_put_contents($file, $secret."\n");

        self::assertSame(Application::USAGE, $this->app()->run(['github', 'secrets', 'set', 'DEPLOY_TOKEN', '--repo', 'acme/app', '--yes']), 'no --repo-less or argv secrets');
        $this->http->json(['key_id' => 'k1', 'key' => base64_encode(sodium_crypto_box_publickey($pair))])->json(null, 201);
        self::assertSame(0, $this->app()->run(['gh', 'secrets', 'set', 'DEPLOY_TOKEN', '--repo', 'acme/app', '--value-file', $file, '--yes']));
        self::assertStringNotContainsString($secret, $this->out());
        $body = MockHttpClient::body($this->http->last());
        self::assertIsString($body['encrypted_value']);
        self::assertSame($secret, sodium_crypto_box_seal_open((string) base64_decode($body['encrypted_value'], true), $pair), 'the trailing newline is stripped');
    }

    public function test_do_ssh_keys_is_the_keys_module(): void
    {
        $this->http->json(['ssh_keys' => [['id' => 1, 'name' => 'laptop', 'fingerprint' => 'aa:bb', 'public_key' => 'ssh-ed25519 AAAA laptop']], 'links' => [], 'meta' => ['total' => 1]]);
        self::assertSame(0, $this->app()->run(['do', 'ssh-keys', 'list']));
        self::assertStringContainsString('laptop', $this->out());
        self::assertStringStartsWith('GET /v2/account/keys', $this->http->log()[0]);
    }

    public function test_github_dispatch_and_runs(): void
    {
        self::assertSame(0, $this->app()->run(['github', 'dispatch', 'deploy.yml', '--repo', 'acme/app', '--ref', 'main', '--inputs', 'env=staging', '--dry-run', '--json']));
        self::assertStringContainsString('"inputs":{"env":"staging"}', (string) preg_replace('/\s+/', '', $this->out()));
        self::assertSame(Application::USAGE, $this->app()->run(['github', 'dispatch', 'deploy.yml', '--repo', 'acme/app', '--ref', 'main', '--inputs', 'novalue', '--dry-run']));

        $this->http->json(['total_count' => 1, 'workflow_runs' => [['id' => 9, 'name' => 'CI', 'head_branch' => 'main', 'event' => 'push', 'status' => 'completed', 'conclusion' => 'success']]]);
        self::assertSame(0, $this->app()->run(['github', 'runs', '--repo', 'acme/app', '--limit', '5']));
        self::assertStringContainsString('success', $this->out());
    }
}
