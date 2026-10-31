<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Http\BearerToken;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Security\Secret;
use Simtabi\VpsServerWorkbench\Support\Data;

/**
 * DigitalOcean API v2.
 *
 *     DigitalOcean::make()->droplets()->list();
 *     DigitalOcean::make()->droplets()->snapshot(123, 'pre-upgrade')->confirm()->wait();
 */
final readonly class DigitalOcean
{
    public const string BASE_URL = 'https://api.digitalocean.com';

    public const string TOKEN = 'DIGITALOCEAN_TOKEN';

    private function __construct(private Transport $transport) {}

    /** Token: the argument, else $DIGITALOCEAN_TOKEN, else the credentials file. */
    public static function make(#[\SensitiveParameter] Secret|string|null $token = null, ?ClientOptions $options = null, ?Credentials $credentials = null): self
    {
        return new self(new Transport(
            'DigitalOcean',
            self::BASE_URL,
            new BearerToken(Credentials::resolve($token, self::TOKEN, $credentials)),
            $options ?? ClientOptions::defaults(),
        ));
    }

    public function droplets(): Droplets
    {
        return new Droplets($this->transport, $this->actions());
    }

    public function snapshots(): Snapshots
    {
        return new Snapshots($this->transport);
    }

    public function firewalls(): Firewalls
    {
        return new Firewalls($this->transport);
    }

    public function uptime(): Uptime
    {
        return new Uptime($this->transport);
    }

    public function monitoring(): Monitoring
    {
        return new Monitoring($this->transport);
    }

    public function actions(): Actions
    {
        return new Actions($this->transport);
    }

    /**
     * The account the token belongs to (a cheap credentials check).
     *
     * @return array<string, mixed>
     */
    public function account(): array
    {
        return array_intersect_key(Data::map($this->transport->get('/v2/account')->json, 'account'), array_flip(['email', 'status', 'droplet_limit', 'uuid']));
    }
}
