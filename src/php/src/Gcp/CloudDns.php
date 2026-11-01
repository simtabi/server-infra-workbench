<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Cloudflare\Data\DnsRecordType;
use Simtabi\VpsServerWorkbench\Exception\NotFoundException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * Cloud DNS v1: managed zones and record sets. Every write is one atomic Change (deletions then
 * additions), so an upsert never leaves a moment with no record. Names are FQDNs with a trailing dot.
 */
final readonly class CloudDns
{
    private Endpoint $zones;

    public function __construct(private Transport $transport, private string $project)
    {
        $this->zones = new Endpoint($transport, 'managed zone', "/projects/{$project}/managedZones", GcpPaginator::list('managedZones'), [
            'name' => 'name', 'dnsName' => 'dnsName', 'visibility' => 'visibility', 'nameServers' => 'nameServers', 'dnssec' => 'dnssecConfig.state',
        ], null, ['maxResults' => 500]);
    }

    /** @return list<Item> */
    public function zones(): array
    {
        return $this->zones->list();
    }

    /** By zone name ("example-com") or DNS name ("example.com"). */
    public function zone(string $zone): Item
    {
        $fqdn = rtrim($zone, '.').'.';
        foreach ($this->zones() as $z) {
            if ($z->string('name') === $zone || $z->string('dnsName') === $fqdn) {
                return $z;
            }
        }

        throw new NotFoundException(sprintf('Cloud DNS zone "%s" not found in %s', $zone, $this->project), 'Google Cloud DNS', 404);
    }

    /**
     * A public zone with DNSSEC on. Idempotent by DNS name.
     *
     * @return PendingAction<Item>
     */
    public function createZone(string $domain, ?string $name = null, string $description = 'managed by workbench'): PendingAction
    {
        $domain = Validate::domain($domain);
        $name = Validate::gcpName($name ?? str_replace('.', '-', $domain), 'zone name');
        foreach ($this->zones() as $z) {
            if ($z->string('dnsName') === $domain.'.') {
                return $this->zones->noop('create zone', "{$domain} (exists: {$z->string('name')})", $z);
            }
        }

        return $this->zones->create(['name' => $name, 'dnsName' => $domain.'.', 'description' => Validate::label($description, 'description', 1024),
            'visibility' => 'public', 'dnssecConfig' => ['state' => 'on']], "{$domain} as {$name}", 'billed per zone-month; point the registrar at the name servers it returns (and add the DS record)');
    }

    /**
     * Destructive. Cloud DNS refuses while the zone still has records other than SOA/NS.
     *
     * @return PendingAction<bool>
     */
    public function deleteZone(string $zone): PendingAction
    {
        $z = $this->zone($zone);

        return $this->zones->delete($z->string('name'), "{$z->string('name')} ({$z->string('dnsName')})", 'delete its records first; the domain stops resolving if the registrar still points here');
    }

    /** @return list<Item> */
    public function records(string $zone, ?string $type = null, ?string $name = null): array
    {
        $z = $this->zone($zone);
        $query = ['maxResults' => 1000];
        if ($name !== null) {
            $query['name'] = $this->fqdn($name, $z);
            if ($type !== null) {
                $query['type'] = DnsRecordType::parse($type)->value;
            }
        }
        $rows = (new Endpoint($this->transport, 'record set', $this->zones->path($z->string('name'), 'rrsets'), GcpPaginator::list('rrsets'),
            ['name' => 'name', 'type' => 'type', 'ttl' => 'ttl', 'data' => 'rrdatas']))->list($query);

        return $type === null ? $rows : array_values(array_filter($rows, static fn (Item $r): bool => $r->string('type') === strtoupper($type)));
    }

    /**
     * Set the record set (type + name) to exactly these values; a no-op when it already matches.
     *
     * @param list<string> $values
     * @return PendingAction<array<mixed>>
     */
    public function upsert(string $zone, string $type, string $name, array $values, int $ttl = 300): PendingAction
    {
        $z = $this->zone($zone);
        $type = DnsRecordType::parse($type)->value;
        $fqdn = $this->fqdn($name, $z);
        Validate::range($ttl, 30, 86400, 'ttl');
        if ($values === []) {
            throw new ValidationException('give at least one value');
        }
        $values = array_map(fn (string $v): string => $this->value($type, $v), $values);
        $current = $this->records($z->string('name'), $type, $fqdn)[0] ?? null;
        $add = ['name' => $fqdn, 'type' => $type, 'ttl' => $ttl, 'rrdatas' => $values];
        $target = "{$type} {$fqdn} -> ".implode(', ', $values);
        if ($current !== null && $current->get('data') === $values && $current->int('ttl') === $ttl) {
            return $this->transport->pending('dns upsert', $target.' (already set)', 'NONE', $this->changes($z), [], self::unchanged(...));
        }
        $change = ['additions' => [$add]] + ($current === null ? [] : ['deletions' => [['name' => $fqdn, 'type' => $type, 'ttl' => $current->int('ttl'), 'rrdatas' => $current->get('data')]]]);

        return $this->change($z, 'dns upsert', $target, $change, false, $current === null ? null : 'replaces '.implode(', ', array_map(strval(...), array_filter((array) $current->get('data'), is_scalar(...)))));
    }

    /** @return PendingAction<array<mixed>> */
    public function delete(string $zone, string $type, string $name): PendingAction
    {
        $z = $this->zone($zone);
        $type = DnsRecordType::parse($type)->value;
        $fqdn = $this->fqdn($name, $z);
        $current = $this->records($z->string('name'), $type, $fqdn)[0]
            ?? throw new NotFoundException(sprintf('no %s record set named %s', $type, $fqdn), 'Google Cloud DNS', 404);

        return $this->change($z, 'dns delete', "{$type} {$fqdn}", ['deletions' => [['name' => $fqdn, 'type' => $type, 'ttl' => $current->int('ttl'), 'rrdatas' => $current->get('data')]]], true, null);
    }

    /**
     * @param array<string, mixed> $change
     * @return PendingAction<array<mixed>>
     */
    private function change(Item $zone, string $action, string $target, array $change, bool $destructive, ?string $note): PendingAction
    {
        $path = $this->changes($zone);

        return $this->transport->pending($action, $target, 'POST', $path, $change, fn (): array => $this->transport->send('POST', $path, [], $change)->json, $destructive, $note);
    }

    /** @return array<mixed> */
    private static function unchanged(): array
    {
        return ['status' => 'unchanged'];
    }

    private function changes(Item $zone): string
    {
        return $this->zones->path($zone->string('name'), 'changes');
    }

    private function fqdn(string $name, Item $zone): string
    {
        $apex = $zone->string('dnsName');
        // "www" and "www.example.com" are relative to the zone unless already inside it; a trailing dot
        // ("www.other.org.") means absolute, and is then refused when it is outside the zone.
        $absolute = str_ends_with($name, '.') && $name !== '.';
        $name = rtrim(Validate::dnsName(rtrim($name, '.')), '.');
        $fqdn = match (true) {
            $name === '@' => $apex,
            $absolute, str_ends_with($name.'.', '.'.$apex), $name.'.' === $apex => $name.'.',
            default => $name.'.'.$apex,
        };
        if ($fqdn !== $apex && ! str_ends_with($fqdn, '.'.$apex)) {
            throw new ValidationException(sprintf('%s is not inside %s', $fqdn, $apex));
        }

        return $fqdn;
    }

    private function value(string $type, string $value): string
    {
        if (in_array($type, ['A', 'AAAA'], true)) {
            return Validate::cidr($value, 'record value');
        }
        if ($value === '' || strlen($value) > 2048 || preg_match('/[\x00-\x1f\x7f]/', $value) === 1) {
            throw new ValidationException('record values must be one printable line');
        }
        if ($type === 'TXT' && ! str_starts_with($value, '"')) {
            return '"'.str_replace('"', '\"', $value).'"';
        }

        return in_array($type, ['CNAME', 'MX', 'NS', 'SRV'], true) && ! str_ends_with($value, '.') ? $value.'.' : $value;
    }
}
