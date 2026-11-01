<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Cloudflare;

use Simtabi\ServerInfraWorkbench\Cloudflare\Data\DnsRecord;
use Simtabi\ServerInfraWorkbench\Cloudflare\Data\DnsRecordType;
use Simtabi\ServerInfraWorkbench\Cloudflare\Data\Zone;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/** DNS records of one zone. */
final readonly class DnsRecords
{
    public function __construct(private Transport $transport, private Zone $zone) {}

    public function zone(): Zone
    {
        return $this->zone;
    }

    /** @return list<DnsRecord> */
    public function list(DnsRecordType|string|null $type = null, ?string $name = null): array
    {
        $query = ['per_page' => 100];
        if ($type !== null) {
            $query['type'] = DnsRecordType::parse($type)->value;
        }
        if ($name !== null) {
            $query['name'] = $this->fqdn($name);
        }
        $out = [];
        foreach ($this->transport->paginate($this->base(), $query, new CloudflarePaginator) as $row) {
            $out[] = DnsRecord::fromArray($row);
        }

        return $out;
    }

    /**
     * Create the record, or update the single existing record of that type and name.
     * Already correct? The action is a no-op and confirm() sends nothing.
     *
     * @return PendingAction<DnsRecord>
     */
    public function upsert(DnsRecordType|string $type, string $name, string $content, int $ttl = 1, bool $proxied = false, ?int $priority = null, ?string $comment = null): PendingAction
    {
        $type = DnsRecordType::parse($type);
        $name = $this->fqdn($name);
        $content = self::content($type, $content);
        if ($ttl !== 1) {
            Validate::range($ttl, 60, 86400, 'ttl (1 = auto)');
        }
        if ($proxied && ! $type->proxiable()) {
            throw new ValidationException(sprintf('%s records cannot be proxied', $type->value));
        }
        if ($type === DnsRecordType::MX) {
            $priority = Validate::range($priority ?? 10, 0, 65535, 'priority');
        }

        $body = array_filter([
            'type' => $type->value, 'name' => $name, 'content' => $content, 'ttl' => $ttl,
            'proxied' => $type->proxiable() ? $proxied : null, 'priority' => $priority, 'comment' => $comment,
        ], static fn (mixed $v): bool => $v !== null);

        $existing = $this->list($type, $name);
        if (count($existing) > 1) {
            throw new ValidationException(sprintf('%d %s records named %s exist; delete the extras first (ids: %s)', count($existing), $type->value, $name, implode(', ', array_map(static fn (DnsRecord $r): string => $r->id, $existing))));
        }
        $current = $existing[0] ?? null;
        $target = "{$type->value} {$name} -> {$content}";

        if ($current !== null && $current->matches($type, $name, $content, $ttl, $proxied, $priority)) {
            return $this->transport->pending('dns upsert', $target, 'NONE', $this->base().'/'.$current->id, $body, static fn (): DnsRecord => $current, note: 'record already matches');
        }
        if ($current !== null) {
            $path = $this->base().'/'.Validate::token($current->id, 'record id');

            return $this->transport->pending('dns update', $target, 'PUT', $path, $body, fn (): DnsRecord => DnsRecord::fromArray(
                CloudflarePaginator::result($this->transport->send('PUT', $path, [], $body)->json),
            ), note: "was {$current->content} (ttl {$current->ttl}".($current->proxied ? ', proxied' : '').')');
        }

        return $this->transport->pending('dns create', $target, 'POST', $this->base(), $body, fn (): DnsRecord => DnsRecord::fromArray(
            CloudflarePaginator::result($this->transport->send('POST', $this->base(), [], $body)->json),
        ));
    }

    /**
     * Destructive.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $recordId): PendingAction
    {
        $path = $this->base().'/'.Validate::token($recordId, 'record id');

        return $this->transport->pending('dns delete', "{$recordId} in {$this->zone->name}", 'DELETE', $path, [], function () use ($path): bool {
            CloudflarePaginator::result($this->transport->send('DELETE', $path)->json);

            return true;
        }, destructive: true);
    }

    /** "@" and short names are expanded to the zone; full names must be inside it. */
    public function fqdn(string $name): string
    {
        $name = Validate::dnsName($name);
        $zone = $this->zone->name;
        if ($name === '@' || $name === $zone) {
            return $zone;
        }
        if (str_ends_with($name, '.'.$zone)) {
            return $name;
        }
        if (! str_contains($name, '.') || str_starts_with($name, '*') || str_starts_with($name, '_')) {
            return $name.'.'.$zone;
        }

        throw new ValidationException(sprintf('record "%s" is not inside zone %s', $name, $zone));
    }

    private function base(): string
    {
        return '/zones/'.Validate::token($this->zone->id, 'zone id').'/dns_records';
    }

    private static function content(DnsRecordType $type, string $content): string
    {
        $ok = match ($type) {
            DnsRecordType::A => filter_var($content, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false,
            DnsRecordType::AAAA => filter_var($content, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false,
            DnsRecordType::CNAME, DnsRecordType::MX, DnsRecordType::NS => self::isDomain($content),
            default => $content !== '' && strlen($content) <= 2048 && preg_match('/[\x00-\x08\x0a-\x1f\x7f]/', $content) !== 1,
        };
        if (! $ok) {
            throw new ValidationException(sprintf('"%s" is not valid content for a %s record', $content, $type->value));
        }

        return in_array($type, [DnsRecordType::CNAME, DnsRecordType::MX, DnsRecordType::NS], true) ? strtolower(rtrim($content, '.')) : $content;
    }

    private static function isDomain(string $value): bool
    {
        try {
            Validate::domain($value);

            return true;
        } catch (ValidationException) {
            return false;
        }
    }
}
