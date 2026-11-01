<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean;

use Simtabi\ServerInfraWorkbench\Cloudflare\Data\DnsRecordType;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Item;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/** Records of one DigitalOcean domain. Names are relative ("@", "www"), as the API stores them. */
final readonly class DomainRecords
{
    private Endpoint $api;

    public function __construct(Transport $transport, private string $domain)
    {
        $this->api = new Endpoint($transport, 'dns record', "/v2/domains/{$domain}/records", new DigitalOceanPaginator('domain_records'), [
            'id' => 'id', 'type' => 'type', 'name' => 'name', 'data' => 'data', 'ttl' => 'ttl', 'priority' => 'priority',
        ], 'domain_record', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(?string $type = null, ?string $name = null): array
    {
        $query = [];
        if ($type !== null) {
            $query['type'] = DnsRecordType::parse($type)->value;
        }
        if ($name !== null) {
            $query['name'] = $this->relative($name) === '@' ? $this->domain : $this->relative($name).'.'.$this->domain;
        }

        return $this->api->list($query);
    }

    /**
     * Create, or update the single record of that type and name; a no-op when it already matches.
     *
     * @return PendingAction<Item>
     */
    public function upsert(string $type, string $name, string $data, int $ttl = 1800, ?int $priority = null): PendingAction
    {
        $type = DnsRecordType::parse($type);
        $name = $this->relative($name);
        Validate::range($ttl, 30, 86400, 'ttl');
        if ($type === DnsRecordType::A || $type === DnsRecordType::AAAA) {
            Validate::cidr($data, 'record data');
        } elseif ($data === '' || strlen($data) > 2048 || preg_match('/[\x00-\x1f\x7f]/', $data) === 1) {
            throw new ValidationException('record data must be one printable line');
        }
        if (in_array($type, [DnsRecordType::CNAME, DnsRecordType::MX, DnsRecordType::NS], true) && ! str_ends_with($data, '.')) {
            $data .= '.'; // DigitalOcean wants FQDN targets with the trailing dot, otherwise it appends the zone
        }
        $body = array_filter(['type' => $type->value, 'name' => $name, 'data' => $data, 'ttl' => $ttl,
            'priority' => $type === DnsRecordType::MX ? Validate::range($priority ?? 10, 0, 65535, 'priority') : null], static fn (mixed $v): bool => $v !== null);
        $existing = $this->list($type->value, $name);
        if (count($existing) > 1) {
            throw new ValidationException(sprintf('%d %s records named %s exist; delete the extras first', count($existing), $type->value, $name));
        }
        $target = "{$type->value} {$name}.{$this->domain} -> {$data}";
        $current = $existing[0] ?? null;
        if ($current === null) {
            return $this->api->create($body, $target);
        }
        if (rtrim($current->string('data'), '.') === rtrim($data, '.') && $current->int('ttl') === $ttl) {
            return $this->api->noop('dns upsert', $target, $current, 'record already matches');
        }

        return $this->api->update($current->int('id'), $body, $target, 'PUT', 'was '.$current->string('data'));
    }

    /** @return PendingAction<bool> */
    public function delete(int|string $id): PendingAction
    {
        return $this->api->delete(Validate::id($id, 'record id'), "{$id} in {$this->domain}");
    }

    private function relative(string $name): string
    {
        $name = Validate::dnsName($name);
        if ($name === '@' || $name === $this->domain) {
            return '@';
        }
        if (str_ends_with($name, '.'.$this->domain)) {
            return substr($name, 0, -strlen('.'.$this->domain));
        }
        if (str_contains($name, '.') && ! str_starts_with($name, '_') && ! str_starts_with($name, '*')) {
            throw new ValidationException(sprintf('record "%s" is not inside %s', $name, $this->domain));
        }

        return $name;
    }
}
