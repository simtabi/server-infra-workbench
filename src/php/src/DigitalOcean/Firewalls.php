<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Firewall;
use Simtabi\VpsServerWorkbench\Exception\NotFoundException;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

/** DigitalOcean cloud firewalls (in front of the droplet; independent of ufw on the host). */
final readonly class Firewalls
{
    public function __construct(private Transport $transport) {}

    /** @return list<Firewall> */
    public function list(): array
    {
        $out = [];
        foreach ($this->transport->paginate('/v2/firewalls', ['per_page' => 200], new DigitalOceanPaginator('firewalls')) as $row) {
            $out[] = Firewall::fromArray($row);
        }

        return $out;
    }

    public function find(string $id): Firewall
    {
        return Firewall::fromArray(Data::map($this->transport->get('/v2/firewalls/'.Validate::token($id, 'firewall id'))->json, 'firewall'));
    }

    public function findByName(string $name): ?Firewall
    {
        foreach ($this->list() as $firewall) {
            if ($firewall->name === $name) {
                return $firewall;
            }
        }

        return null;
    }

    /**
     * Create the firewall, or replace the rules of the one with the same name. A no-op when the rules
     * and targets already match.
     *
     * @param array<string, mixed> $body as built by FirewallPreset::build() (or by hand, same shape)
     * @return PendingAction<Firewall>
     */
    public function apply(array $body): PendingAction
    {
        $name = Validate::label(is_string($body['name'] ?? null) ? $body['name'] : '', 'firewall name');
        $existing = $this->findByName($name);
        if ($existing === null) {
            return $this->transport->pending(
                'create firewall',
                "\"{$name}\"",
                'POST',
                '/v2/firewalls',
                $body,
                fn (): Firewall => Firewall::fromArray(Data::map($this->transport->send('POST', '/v2/firewalls', [], $body)->json, 'firewall')),
                note: 'applies to the listed droplets/tags immediately; SSH stays open per the rules',
            );
        }
        $path = '/v2/firewalls/'.Validate::token($existing->id, 'firewall id');
        if (self::same($existing, $body)) {
            return $this->transport->pending('update firewall', "\"{$name}\"", 'NONE', $path, [], static fn (): Firewall => $existing);
        }

        return $this->transport->pending(
            'update firewall',
            "\"{$name}\" ({$existing->id})",
            'PUT',
            $path,
            $body,
            fn (): Firewall => Firewall::fromArray(Data::map($this->transport->send('PUT', $path, [], $body)->json, 'firewall')),
            note: 'replaces all rules and targets of this firewall',
        );
    }

    /** @return PendingAction<bool> */
    public function delete(string $id): PendingAction
    {
        $path = '/v2/firewalls/'.Validate::token($id, 'firewall id');

        return $this->transport->pending('delete firewall', $id, 'DELETE', $path, [],
            fn (): bool => $this->transport->send('DELETE', $path)->status === 204, destructive: true,
            note: 'the droplets lose this protection at once');
    }

    /** IP range of a VPC, for the db preset. */
    public function vpcCidr(string $vpcId): string
    {
        $range = Data::string(Data::map($this->transport->get('/v2/vpcs/'.Validate::token($vpcId, 'vpc id'))->json, 'vpc'), 'ip_range');

        return $range !== '' ? $range : throw new NotFoundException("VPC {$vpcId} has no ip_range");
    }

    /** @param array<string, mixed> $body */
    private static function same(Firewall $existing, array $body): bool
    {
        $norm = static fn (mixed $v): string => json_encode(self::sortDeep($v), JSON_THROW_ON_ERROR);

        return $norm($existing->inboundRules) === $norm($body['inbound_rules'] ?? [])
            && $norm($existing->outboundRules) === $norm($body['outbound_rules'] ?? [])
            && $norm($existing->dropletIds) === $norm($body['droplet_ids'] ?? [])
            && $norm($existing->tags) === $norm($body['tags'] ?? []);
    }

    private static function sortDeep(mixed $value): mixed
    {
        if (! is_array($value)) {
            return $value;
        }
        // drop empty source/destination lists DigitalOcean echoes back
        $value = array_filter($value, static fn (mixed $v): bool => $v !== [] && $v !== null);
        $value = array_map(self::sortDeep(...), $value);
        if (array_is_list($value)) {
            usort($value, static fn (mixed $a, mixed $b): int => strcmp((string) json_encode($a), (string) json_encode($b)));
        } else {
            ksort($value);
        }

        return $value;
    }
}
