<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Cloudflare;

use Simtabi\VpsServerWorkbench\Cloudflare\Data\Zone;
use Simtabi\VpsServerWorkbench\Exception\NotFoundException;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Zones
{
    public function __construct(private Transport $transport) {}

    /** @return list<Zone> */
    public function list(?string $name = null): array
    {
        $query = ['per_page' => 50];
        if ($name !== null) {
            $query['name'] = Validate::domain($name, 'zone');
        }
        $out = [];
        foreach ($this->transport->paginate('/zones', $query, new CloudflarePaginator) as $row) {
            $out[] = Zone::fromArray($row);
        }

        return $out;
    }

    /** By zone name ("example.com") or 32-character zone id. */
    public function find(string $zone): Zone
    {
        if (self::isId($zone)) {
            return Zone::fromArray(CloudflarePaginator::result($this->transport->get('/zones/'.$zone)->json));
        }

        return $this->list($zone)[0] ?? throw new NotFoundException(sprintf('Cloudflare zone "%s" not found (or the token cannot see it)', $zone), 'Cloudflare', 404);
    }

    public function dns(string $zone): DnsRecords
    {
        return new DnsRecords($this->transport, $this->find($zone));
    }

    public function settings(string $zone): ZoneSettings
    {
        return new ZoneSettings($this->transport, $this->find($zone));
    }

    public function originCertificates(string $zone): OriginCertificates
    {
        return new OriginCertificates($this->transport, $this->find($zone));
    }

    public function firewall(string $zone): Firewall
    {
        return new Firewall($this->transport, $this->find($zone));
    }

    public function cache(string $zone): Cache
    {
        return new Cache($this->transport, $this->find($zone));
    }

    public static function isId(string $value): bool
    {
        return preg_match('/^[a-f0-9]{32}$/', $value) === 1;
    }
}
