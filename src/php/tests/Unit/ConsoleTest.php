<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\Console\Application;
use Simtabi\VpsServerWorkbench\Console\Output;
use Simtabi\VpsServerWorkbench\Console\ProviderFactory;
use Simtabi\VpsServerWorkbench\Gcp\Auth\StaticTokenProvider;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class ConsoleTest extends TestCase
{
    /** @var resource */
    private $stdout;

    /** @var resource */
    private $stderr;

    /** @var list<string> */
    private array $prompts = [];

    private bool $answer = false;

    /** @param array<string, string> $env */
    private function app(?array $env = null): Application
    {
        $env ??= ['DIGITALOCEAN_TOKEN' => self::fake('do'), 'CLOUDFLARE_API_TOKEN' => self::fake('cf'), 'PLOI_API_TOKEN' => self::fake('ploi'), 'GCP_PROJECT' => 'proj-123'];
        $this->stdout = self::memory();
        $this->stderr = self::memory();

        return new Application(
            new ProviderFactory($this->options(), new Credentials('/nonexistent/credentials', $env), new StaticTokenProvider('ya29'.'.static')),
            new Output($this->stdout, $this->stderr),
            function (string $description): bool {
                $this->prompts[] = $description;

                return $this->answer;
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

    public function test_lists_as_table_and_json(): void
    {
        $this->http->json(['droplets' => [['id' => 7, 'name' => 'db', 'status' => 'active', 'region' => ['slug' => 'nyc3']]]]);
        self::assertSame(0, $this->app()->run(['do', 'droplets']));
        self::assertMatchesRegularExpression('/ID\s+NAME\s+STATUS.*\n7\s+db\s+active\s+nyc3/', $this->out());

        $this->http->json(['droplets' => [['id' => 7, 'name' => 'db', 'status' => 'active']]]);
        self::assertSame(0, $this->app()->run(['do', 'droplets', '--json']));
        $json = json_decode($this->out(), true, flags: JSON_THROW_ON_ERROR);
        self::assertIsArray($json);
        self::assertIsArray($json[0]);
        self::assertSame('db', $json[0]['name']);
    }

    public function test_dry_run_sends_nothing(): void
    {
        self::assertSame(0, $this->app()->run(['do', 'snapshot', '123', '--name', 'pre-upgrade', '--dry-run']));
        self::assertSame([], $this->http->requests);
        self::assertStringContainsString('DRY RUN — nothing sent. Would do: DigitalOcean: snapshot droplet 123 as "pre-upgrade" (POST /v2/droplets/123/actions)', $this->out());
    }

    public function test_writes_ask_and_refuse_without_yes(): void
    {
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['ploi', 'deploy', '12', '34']));
        self::assertCount(1, $this->prompts);
        self::assertSame([], $this->http->requests);
        self::assertStringContainsString('pass --yes', $this->err());

        $this->answer = true;
        $this->http->json(['message' => 'queued']);
        self::assertSame(0, $this->app()->run(['ploi', 'deploy', '12', '34']));
        self::assertSame(['POST /api/servers/12/sites/34/deploy'], $this->http->log());
    }

    public function test_yes_skips_the_prompt(): void
    {
        $this->http->json(['action' => ['id' => 1, 'status' => 'in-progress', 'type' => 'snapshot']], 201);
        self::assertSame(0, $this->app()->run(['do', 'snapshot', '123', '--yes']));
        self::assertSame([], $this->prompts);
        self::assertStringContainsString('snapshot started', $this->out());
    }

    public function test_destructive_needs_force_even_with_yes(): void
    {
        self::assertSame(Application::NOT_CONFIRMED, $this->app()->run(['do', 'snapshot-delete', '999', '--yes']));
        self::assertStringContainsString('--force', $this->err());
        self::assertSame([], $this->http->requests);

        $this->http->push(new \GuzzleHttp\Psr7\Response(204));
        self::assertSame(0, $this->app()->run(['do', 'snapshot-delete', '999', '--yes', '--force']));
    }

    public function test_bad_input_is_usage_error_before_any_request(): void
    {
        foreach ([['do', 'droplet', 'abc'], ['do', 'droplets', '--bogus'], ['cf', 'dns', 'list'], ['nope'], ['gcp', 'snapshot', 'Bad_Zone', 'disk'], ['do', 'snapshot', '1', '--name']] as $argv) {
            self::assertSame(Application::USAGE, $this->app()->run($argv), implode(' ', $argv));
        }
        self::assertSame([], $this->http->requests);
    }

    public function test_missing_credentials_exit_4_and_credentials_command_never_prints_values(): void
    {
        self::assertSame(Application::CREDENTIALS, $this->app([])->run(['ploi', 'servers']));
        self::assertStringContainsString('PLOI_API_TOKEN is not set', $this->err());

        self::assertSame(0, $this->app()->run(['credentials']));
        self::assertMatchesRegularExpression('/PLOI_API_TOKEN\s+env/', $this->out());
        self::assertMatchesRegularExpression('/GOOGLE_APPLICATION_CREDENTIALS\s+missing/', $this->out());
        self::assertStringNotContainsString(self::fake('ploi'), $this->out());
    }

    public function test_api_errors_exit_1_with_redacted_message(): void
    {
        $this->http->json(['message' => 'Unauthenticated. token '.self::fake('do')], 401);
        self::assertSame(Application::FAILED, $this->app()->run(['do', 'droplets']));
        self::assertStringContainsString('HTTP 401', $this->err());
        self::assertStringNotContainsString(self::fake('do'), $this->err());
    }

    public function test_cf_upsert_and_gcp_instances(): void
    {
        $this->http
            ->json(['success' => true, 'result' => [['id' => '0123456789abcdef0123456789abcdef', 'name' => 'example.com']], 'result_info' => ['page' => 1, 'total_pages' => 1]])
            ->json(['success' => true, 'result' => [], 'result_info' => ['page' => 1, 'total_pages' => 1]])
            ->json(['success' => true, 'result' => ['id' => 'r9', 'type' => 'A', 'name' => 'db.example.com', 'content' => '203.0.113.7', 'ttl' => 1]]);
        self::assertSame(0, $this->app()->run(['cf', 'dns', 'upsert', 'example.com', 'A', 'db', '203.0.113.7', '-y']));
        self::assertStringContainsString('record saved', $this->out());

        $this->http->json(['items' => ['zones/us-east1-b' => ['instances' => [['name' => 'vm-1', 'zone' => 'z/us-east1-b', 'status' => 'RUNNING']]]]]);
        self::assertSame(0, $this->app()->run(['gcp', 'instances']));
        self::assertMatchesRegularExpression('/vm-1\s+us-east1-b\s+RUNNING/', $this->out());
    }

    public function test_help_and_version(): void
    {
        self::assertSame(0, $this->app()->run(['help']));
        self::assertStringContainsString('workbench do ...', $this->out());
        self::assertSame(0, $this->app()->run(['cf', '--help']));
        self::assertStringContainsString('dns upsert', $this->out());
        self::assertSame(0, $this->app()->run(['--version']));
    }
}
