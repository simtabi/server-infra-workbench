<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Fixtures;

use GuzzleHttp\Client;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;

/**
 * A real Guzzle client whose requests all go to the local mock server (tests/Fixtures/MockApi).
 * The production clients keep their https:// base URLs; only the connection is redirected, and the
 * original host travels in X-Mock-Host so the router can tell the providers apart.
 */
final readonly class LoopbackHttpClient implements ClientInterface
{
    private Client $guzzle;

    public function __construct(private int $port)
    {
        $this->guzzle = new Client(['http_errors' => false, 'allow_redirects' => false, 'timeout' => 10]);
    }

    public function sendRequest(RequestInterface $request): ResponseInterface
    {
        $uri = $request->getUri();
        $local = $uri->withScheme('http')->withHost('127.0.0.1')->withPort($this->port);

        return $this->guzzle->sendRequest($request->withUri($local, true)->withHeader('X-Mock-Host', $uri->getHost()));
    }
}
