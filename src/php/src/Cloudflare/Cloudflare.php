<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Cloudflare;

use Simtabi\ServerInfraWorkbench\Http\BearerToken;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Security\Secret;
use Simtabi\ServerInfraWorkbench\Support\Data;

/**
 * Cloudflare API v4 with a scoped API token (Zone:Read + DNS:Edit is enough).
 *
 *     Cloudflare::make()->zones()->dns('example.com')->upsert('A', 'db.example.com', '203.0.113.7')->confirm();
 */
final readonly class Cloudflare
{
    public const string BASE_URL = 'https://api.cloudflare.com/client/v4';

    public const string TOKEN = 'CLOUDFLARE_API_TOKEN';

    private function __construct(private Transport $transport) {}

    public static function make(#[\SensitiveParameter] Secret|string|null $token = null, ?ClientOptions $options = null, ?Credentials $credentials = null): self
    {
        return new self(new Transport(
            'Cloudflare',
            self::BASE_URL,
            new BearerToken(Credentials::resolve($token, self::TOKEN, $credentials)),
            $options ?? ClientOptions::defaults(),
        ));
    }

    public function zones(): Zones
    {
        return new Zones($this->transport);
    }

    /** Shortcut for zones()->dns($zone). */
    public function dns(string $zone): DnsRecords
    {
        return $this->zones()->dns($zone);
    }

    /** Checks the token is valid and active. */
    public function verifyToken(): string
    {
        return Data::string(CloudflarePaginator::result($this->transport->get('/user/tokens/verify')->json), 'status', 'unknown');
    }
}
