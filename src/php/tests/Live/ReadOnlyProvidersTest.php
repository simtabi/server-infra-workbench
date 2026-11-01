<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Live;

use PHPUnit\Framework\TestCase;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;
use Simtabi\ServerInfraWorkbench\Cloudflare\Cloudflare;
use Simtabi\ServerInfraWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\ServerInfraWorkbench\Gcp\Gcp;
use Simtabi\ServerInfraWorkbench\Github\Github;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;
use Simtabi\ServerInfraWorkbench\Ploi\Ploi;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Support\Env;

/**
 * Live, READ-ONLY smoke tests against the real APIs. Not part of the default run:
 *
 *   SIW_LIVE=1 DIGITALOCEAN_TOKEN=... vendor/bin/phpunit --testsuite live
 *
 * Each provider is skipped unless SIW_LIVE=1 and its token is set. Every request goes through a client
 * that refuses anything but GET (plus the OAuth token POST for a GCP service account), so a bug here
 * can never change an account. Nothing is printed; assertions only check shapes.
 */
final class ReadOnlyProvidersTest extends TestCase
{
    /** @var \ArrayObject<int, string> requests sent (method host path), for the "something was called" checks */
    private \ArrayObject $seen;

    protected function setUp(): void
    {
        $this->seen = new \ArrayObject;
    }

    private function options(): ClientOptions
    {
        $guard = new class(ClientOptions::defaults()->httpClient(), $this->seen) implements ClientInterface
        {
            /** @param \ArrayObject<int, string> $seen */
            public function __construct(private ClientInterface $inner, private \ArrayObject $seen) {}

            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                $oauth = $request->getMethod() === 'POST' && $request->getUri()->getHost() === 'oauth2.googleapis.com';
                if ($request->getMethod() !== 'GET' && ! $oauth) {
                    throw new \LogicException('live tests are read-only; refused '.$request->getMethod().' '.$request->getUri()->getPath());
                }
                $this->seen[] = $request->getMethod().' '.$request->getUri()->getHost().$request->getUri()->getPath();

                return $this->inner->sendRequest($request);
            }
        };

        return ClientOptions::defaults()->withHttpClient($guard)->withTimeout(20, 5);
    }

    private static function need(string ...$keys): Credentials
    {
        if (Env::get('SIW_LIVE') !== '1') {
            self::markTestSkipped('set SIW_LIVE=1 to run live read-only tests');
        }
        $credentials = Credentials::fromEnvironment();
        foreach ($keys as $key) {
            if (! $credentials->has($key)) {
                self::markTestSkipped("{$key} is not set");
            }
        }

        return $credentials;
    }

    public function test_digitalocean(): void
    {
        $do = DigitalOcean::make(null, $this->options(), self::need(DigitalOcean::TOKEN));
        self::assertArrayHasKey('status', $do->account());
        self::assertNotEmpty($do->catalog()->regions());
        self::assertNotEmpty($do->catalog()->sizes());
        $do->droplets()->list();
        $do->volumes()->list();
        $do->vpcs()->list();
        $do->domains()->list();
        $do->reservedIps()->list();
        $do->projects()->list();
        $do->tags()->list();
        $do->firewalls()->list();
        $do->spacesKeys()->list();
        $do->snapshots()->list();
        $do->monitoring()->policies();
        $do->uptime()->checks();
        self::assertGreaterThanOrEqual(15, count($this->seen), 'every read reached the API');
    }

    public function test_cloudflare(): void
    {
        $cf = Cloudflare::make(null, $this->options(), self::need(Cloudflare::TOKEN));
        self::assertSame('active', $cf->verifyToken());
        $zones = $cf->zones()->list();
        if ($zones !== []) {
            $cf->dns($zones[0]->id)->list();
            self::assertArrayHasKey('ssl', $cf->zones()->settings($zones[0]->id)->all());
        }
    }

    public function test_github(): void
    {
        $gh = Github::make(null, $this->options(), self::need(Github::TOKEN));
        self::assertNotSame('', $gh->user()->string('login'));
        self::assertGreaterThan(0, $gh->rateLimit()->int('limit'));
        $repos = $gh->repositories(null, 5);
        if ($repos !== []) {
            $repo = $gh->repo($repos[0]->string('fullName'));
            $repo->releases()->list(5);
            $repo->workflows()->list();
        }
    }

    public function test_ploi(): void
    {
        $ploi = Ploi::make(null, $this->options(), self::need(Ploi::TOKEN));
        $ploi->servers()->list();
        self::assertNotEmpty(array_filter($this->seen->getArrayCopy(), static fn (string $r): bool => str_contains($r, '/servers')));
    }

    public function test_gcp(): void
    {
        $gcp = Gcp::make(null, null, $this->options(), self::need(Gcp::KEY_FILE, Gcp::PROJECT));
        $gcp->instances()->list();
        $gcp->firewalls()->list();
        $gcp->dns()->zones();
        $gcp->storage()->list();
        self::assertGreaterThanOrEqual(4, count($this->seen));
    }
}
