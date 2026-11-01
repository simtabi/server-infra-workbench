<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/** DNS domains hosted on DigitalOcean (only useful when the registrar points at ns1-3.digitalocean.com). */
final readonly class Domains
{
    private Endpoint $api;

    public function __construct(private Transport $transport)
    {
        $this->api = new Endpoint($transport, 'domain', '/v2/domains', new DigitalOceanPaginator('domains'), [
            'name' => 'name', 'ttl' => 'ttl',
        ], 'domain', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * Idempotent. With $ip, DigitalOcean also creates an A record for the apex.
     *
     * @return PendingAction<Item>
     */
    public function create(string $name, ?string $ip = null): PendingAction
    {
        $name = Validate::domain($name);
        foreach ($this->list() as $domain) {
            if ($domain->string('name') === $name) {
                return $this->api->noop('create domain', "{$name} (exists)", $domain);
            }
        }
        $body = ['name' => $name] + ($ip === null ? [] : ['ip_address' => Validate::cidr($ip, 'ip address')]);

        return $this->api->create($body, $name.($ip !== null ? " -> {$ip}" : ''), 'resolves only once the registrar uses DigitalOcean name servers');
    }

    /**
     * Destructive: every record in the zone goes with it.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $name): PendingAction
    {
        return $this->api->delete(Validate::domain($name), note: 'deletes every record in the zone');
    }

    public function records(string $domain): DomainRecords
    {
        return new DomainRecords($this->transport, Validate::domain($domain));
    }
}
