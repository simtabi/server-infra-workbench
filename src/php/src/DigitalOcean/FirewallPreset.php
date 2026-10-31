<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * Recommended cloud-firewall rule sets. SSH stays reachable (from the sources you give, by default
 * anywhere: key-only SSH is the norm on these servers), so applying a preset cannot lock you out.
 *
 *  - db:  SSH; database ports (Postgres, PgBouncer, MySQL, MariaDB, Redis, MongoDB) and ICMP from the VPC only.
 *  - web: SSH; HTTP/HTTPS from anywhere; ICMP; everything else closed.
 *
 * Outbound is open (package updates, backups, APIs), which matches DigitalOcean's default.
 */
final class FirewallPreset
{
    /** Default DB ports the db manager uses (see config/db-server.env.example). */
    public const array DB_PORTS = [5432, 6432, 3306, 3307, 6379, 27017];

    public const array ROLES = ['db', 'web'];

    /**
     * @param list<string>   $sshFrom   CIDRs allowed to SSH (default: anywhere)
     * @param list<int>      $dbPorts
     * @param list<int>      $dropletIds
     * @param list<string>   $tags
     * @return array<string, mixed> the DigitalOcean firewall body
     */
    public static function build(string $role, string $name, string $vpcCidr, array $sshFrom = [], array $dbPorts = self::DB_PORTS, array $dropletIds = [], array $tags = []): array
    {
        if (! in_array($role, self::ROLES, true)) {
            throw new ValidationException(sprintf('firewall preset must be one of: %s', implode(', ', self::ROLES)));
        }
        $vpcCidr = self::cidr($vpcCidr);
        $sshFrom = $sshFrom === [] ? ['0.0.0.0/0', '::/0'] : array_map(self::cidr(...), $sshFrom);
        if ($dropletIds === [] && $tags === []) {
            throw new ValidationException('a firewall needs targets: --droplet ID[,ID] or --tag T');
        }

        $inbound = [self::rule('tcp', '22', $sshFrom)];
        if ($role === 'db') {
            foreach (array_values(array_unique($dbPorts)) as $port) {
                $inbound[] = self::rule('tcp', (string) Validate::range($port, 1, 65535, 'port'), [$vpcCidr]);
            }
            $inbound[] = ['protocol' => 'icmp', 'sources' => ['addresses' => [$vpcCidr]]];
        } else {
            $inbound[] = self::rule('tcp', '80', ['0.0.0.0/0', '::/0']);
            $inbound[] = self::rule('tcp', '443', ['0.0.0.0/0', '::/0']);
            $inbound[] = ['protocol' => 'icmp', 'sources' => ['addresses' => ['0.0.0.0/0', '::/0']]];
        }
        $anywhere = ['addresses' => ['0.0.0.0/0', '::/0']];

        return [
            'name' => Validate::label($name, 'firewall name'),
            'inbound_rules' => $inbound,
            'outbound_rules' => [
                ['protocol' => 'tcp', 'ports' => 'all', 'destinations' => $anywhere],
                ['protocol' => 'udp', 'ports' => 'all', 'destinations' => $anywhere],
                ['protocol' => 'icmp', 'destinations' => $anywhere],
            ],
            'droplet_ids' => array_values(array_map(static fn (int $id): int => Validate::id($id, 'droplet id'), $dropletIds)),
            'tags' => array_values(array_map(static fn (string $t): string => Validate::label($t, 'tag'), $tags)),
        ];
    }

    public static function cidr(string $value): string
    {
        if (preg_match('#^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$#', $value, $m) === 1) {
            foreach ([1, 2, 3, 4] as $i) {
                if ((int) $m[$i] > 255) {
                    throw new ValidationException(sprintf('"%s" is not a valid CIDR', $value));
                }
            }
            if ((int) $m[5] > 32) {
                throw new ValidationException(sprintf('"%s" is not a valid CIDR', $value));
            }

            return $value;
        }
        if ($value === '::/0' || preg_match('#^[0-9a-fA-F:]+/\d{1,3}$#', $value) === 1 && filter_var(explode('/', $value)[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false) {
            return $value;
        }
        if (filter_var($value, FILTER_VALIDATE_IP) !== false) {
            return $value;
        }

        throw new ValidationException(sprintf('"%s" is not a valid IP or CIDR', $value));
    }

    /**
     * @param list<string> $addresses
     * @return array<string, mixed>
     */
    private static function rule(string $protocol, string $ports, array $addresses): array
    {
        return ['protocol' => $protocol, 'ports' => $ports, 'sources' => ['addresses' => $addresses]];
    }
}
