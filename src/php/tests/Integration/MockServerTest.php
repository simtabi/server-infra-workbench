<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Integration;

use Simtabi\VpsServerWorkbench\Cloudflare\Cloudflare;
use Simtabi\VpsServerWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\VpsServerWorkbench\Exception\ApiException;
use Simtabi\VpsServerWorkbench\Exception\AuthenticationException;
use Simtabi\VpsServerWorkbench\Exception\NotFoundException;
use Simtabi\VpsServerWorkbench\Exception\TransportException;
use Simtabi\VpsServerWorkbench\Gcp\Auth\ServiceAccountTokenProvider;
use Simtabi\VpsServerWorkbench\Gcp\Gcp;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Ploi\Ploi;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\LoopbackHttpClient;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

/**
 * The four clients against a real HTTP server (php -S + tests/Fixtures/MockApi/router.php) through the
 * real Guzzle client: auth headers, pagination, Retry-After, error mapping, the redirect refusal,
 * JSON and form bodies, and the Google service-account JWT (signed with a key generated per run).
 */
final class MockServerTest extends TestCase
{
    /** @var resource|null */
    private static $server = null;

    private static int $port = 0;

    private static string $state = '';

    public static function setUpBeforeClass(): void
    {
        self::$state = sys_get_temp_dir().'/vsw-mockapi-'.bin2hex(random_bytes(6));
        mkdir(self::$state, 0o700, true);
        $sock = stream_socket_server('tcp://127.0.0.1:0');
        self::assertNotFalse($sock);
        self::$port = (int) substr((string) strrchr((string) stream_socket_get_name($sock, false), ':'), 1);
        fclose($sock);

        $router = dirname(__DIR__).'/Fixtures/MockApi/router.php';
        $env = ['MOCK_API_STATE' => self::$state, 'PATH' => (string) getenv('PATH')];
        $proc = proc_open([PHP_BINARY, '-S', '127.0.0.1:'.self::$port, $router], [1 => ['file', self::$state.'/server.log', 'a'], 2 => ['file', self::$state.'/server.log', 'a']], $pipes, null, $env);
        self::assertIsResource($proc);
        self::$server = $proc;
        for ($i = 0; $i < 100; $i++) {
            $c = @fsockopen('127.0.0.1', self::$port, $errno, $errstr, 0.1);
            if ($c !== false) {
                fclose($c);

                return;
            }
            usleep(50_000);
        }
        self::fail('mock server did not start: '.(string) @file_get_contents(self::$state.'/server.log'));
    }

    public static function tearDownAfterClass(): void
    {
        if (self::$server !== null) {
            proc_terminate(self::$server);
            proc_close(self::$server);
        }
        exec('rm -rf '.escapeshellarg(self::$state));
    }

    protected function setUp(): void
    {
        parent::setUp();
        @unlink(self::$state.'/requests.jsonl');
        $hits = glob(self::$state.'/hits-*');
        array_map('unlink', $hits === false ? [] : $hits);
        $this->expect(['token' => self::token()]);
    }

    /** @param array<string, string> $values */
    private function expect(array $values): void
    {
        file_put_contents(self::$state.'/expect.json', (string) json_encode($values));
    }

    private function wire(): ClientOptions
    {
        return $this->options()->withHttpClient(new LoopbackHttpClient(self::$port));
    }

    /** @return list<array{host: string, method: string, path: string, query: array<string, string>, auth: string, ua: string, type: string, accept: string, body: string}> */
    private function requests(): array
    {
        $out = [];
        $lines = file(self::$state.'/requests.jsonl', FILE_IGNORE_NEW_LINES);
        foreach ($lines === false ? [] : $lines as $line) {
            $r = json_decode($line, true);
            self::assertIsArray($r);
            $str = static fn (string $k): string => is_string($r[$k] ?? null) ? $r[$k] : '';
            $query = [];
            foreach (is_array($r['query'] ?? null) ? $r['query'] : [] as $k => $v) {
                $query[(string) $k] = is_scalar($v) ? (string) $v : '';
            }
            $out[] = ['host' => $str('host'), 'method' => $str('method'), 'path' => $str('path'), 'query' => $query, 'auth' => $str('auth'),
                'ua' => $str('ua'), 'type' => $str('type'), 'accept' => $str('accept'), 'body' => $str('body')];
        }

        return $out;
    }

    private function noCredentials(): Credentials
    {
        return new Credentials(null, []);
    }

    public function test_digitalocean_retries_429_with_retry_after_and_sends_the_bearer_token(): void
    {
        $account = DigitalOcean::make(self::token(), $this->wire(), $this->noCredentials())->account();

        self::assertSame('ops@example.com', $account['email']);
        self::assertArrayNotHasKey('team', $account);
        self::assertSame([2000], $this->sleeper->sleeps, 'Retry-After: 2 is honoured');
        $req = $this->requests();
        self::assertCount(2, $req);
        self::assertSame('Bearer '.self::token(), $req[1]['auth']);
        self::assertStringStartsWith('vps-server-workbench/', $req[1]['ua']);
        self::assertSame('application/json', $req[1]['accept']);
    }

    public function test_digitalocean_walks_every_page(): void
    {
        $droplets = DigitalOcean::make(self::token(), $this->wire(), $this->noCredentials())->droplets()->list();

        self::assertSame(['web-1', 'web-2'], array_map(static fn ($d): string => $d->name, $droplets));
        self::assertSame('10.0.0.2', $droplets[1]->privateIpv4);
        self::assertSame(['1', '2'], array_map(static fn (array $r): string => $r['query']['page'] ?? '1', $this->requests()));
    }

    public function test_digitalocean_maps_401_and_404_and_never_leaks_the_token(): void
    {
        $bad = self::fake('wrong');
        try {
            DigitalOcean::make($bad, $this->wire(), $this->noCredentials())->droplets()->find(1);
            self::fail('expected 401');
        } catch (AuthenticationException $e) {
            self::assertStringNotContainsString($bad, $e->getMessage());
        }

        $this->expectException(NotFoundException::class);
        DigitalOcean::make(self::token(), $this->wire(), $this->noCredentials())->droplets()->find(404);
    }

    public function test_a_redirect_is_refused_not_followed_with_credentials(): void
    {
        try {
            DigitalOcean::make(self::token(), $this->wire(), $this->noCredentials())->droplets()->find(302);
            self::fail('expected the redirect to be refused');
        } catch (TransportException $e) {
            self::assertStringContainsString('refusing to follow', $e->getMessage());
        }
        foreach ($this->requests() as $r) {
            self::assertNotSame('evil.example.net', $r['host']);
        }
    }

    public function test_digitalocean_snapshot_posts_a_json_body(): void
    {
        DigitalOcean::make(self::token(), $this->wire(), $this->noCredentials())->droplets()->snapshot(7, 'pre-upgrade')->confirm();

        $post = array_values(array_filter($this->requests(), static fn (array $r): bool => $r['method'] === 'POST'))[0];
        self::assertSame('/v2/droplets/7/actions', $post['path']);
        self::assertStringStartsWith('application/json', $post['type']);
        self::assertSame(['type' => 'snapshot', 'name' => 'pre-upgrade'], json_decode($post['body'], true));
    }

    public function test_ploi_paginates_by_meta(): void
    {
        $servers = Ploi::make(self::token(), $this->wire(), $this->noCredentials())->servers()->list();

        self::assertSame(['ploi-1', 'ploi-2'], array_map(static fn ($s): string => $s->name, $servers));
        self::assertSame('ploi.io', $this->requests()[0]['host']);
        self::assertSame('Bearer '.self::token(), $this->requests()[0]['auth']);
    }

    public function test_cloudflare_paginates_and_treats_success_false_as_an_error(): void
    {
        $cf = Cloudflare::make(self::token(), $this->wire(), $this->noCredentials());
        self::assertSame(['zone1.example', 'zone2.example'], array_map(static fn ($z): string => $z->name, $cf->zones()->list()));

        $this->expectException(ApiException::class);
        $this->expectExceptionMessage('zone lookup failed');
        $cf->zones()->list('broken.example');
    }

    public function test_gcp_service_account_jwt_flow_and_aggregated_pages(): void
    {
        $key = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        self::assertNotFalse($key);
        openssl_pkey_export($key, $pem);
        $details = openssl_pkey_get_details($key);
        self::assertIsArray($details);
        self::assertIsString($details['key']);
        $public = $details['key'];
        $this->expect(['token' => self::token(), 'sa_public' => $public]);

        $file = $this->tempDir().'/sa.json';
        file_put_contents($file, (string) json_encode(['type' => 'service_account', 'project_id' => 'demo-project', 'client_email' => 'ci@demo-project.iam.gserviceaccount.com',
            'private_key' => $pem, 'token_uri' => 'https://oauth2.googleapis.com/token']));
        chmod($file, 0o600);
        $options = $this->wire();

        $vms = Gcp::make(null, ServiceAccountTokenProvider::fromFile($file, $options), $options, $this->noCredentials())->instances()->list();

        self::assertSame(['vm-a', 'vm-b'], array_map(static fn ($i): string => $i->name, $vms));
        $req = $this->requests();
        self::assertSame('oauth2.googleapis.com', $req[0]['host']);
        self::assertStringStartsWith('application/x-www-form-urlencoded', $req[0]['type']);
        self::assertStringNotContainsString('PRIVATE KEY', $req[0]['body']);
        self::assertSame('/compute/v1/projects/demo-project/aggregated/instances', $req[1]['path']);
        self::assertSame('Bearer '.self::token(), $req[1]['auth']);
        self::assertSame('p2', $req[2]['query']['pageToken'] ?? null);
        self::assertCount(3, $req, 'one token request, cached for the second page');
    }
}
