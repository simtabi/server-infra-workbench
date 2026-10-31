<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\AlertPolicy;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * DigitalOcean Monitoring alert policies. Memory, disk and load need the DO metrics agent on the droplet
 * (`monitoring: true` at create time, or `curl -sSL https://repos.insights.digitalocean.com/install.sh | sudo bash`).
 * Idempotent by description: an existing policy with the same description is left alone.
 */
final readonly class Monitoring
{
    /** short name => API type */
    public const array TYPES = [
        'cpu' => 'v1/insights/droplet/cpu',
        'memory' => 'v1/insights/droplet/memory_utilization_percent',
        'disk' => 'v1/insights/droplet/disk_utilization_percent',
        'load1' => 'v1/insights/droplet/load_1',
        'load5' => 'v1/insights/droplet/load_5',
        'load15' => 'v1/insights/droplet/load_15',
        'bandwidth-out' => 'v1/insights/droplet/public_outbound_bandwidth',
    ];

    public const array WINDOWS = ['5m', '10m', '30m', '1h'];

    /** The standard set: [type, threshold %, window]. */
    public const array STANDARD = [['cpu', 85, '10m'], ['memory', 90, '10m'], ['disk', 85, '5m']];

    public function __construct(private Transport $transport) {}

    /** @return list<AlertPolicy> */
    public function policies(): array
    {
        $out = [];
        foreach ($this->transport->paginate('/v2/monitoring/alerts', ['per_page' => 200], new DigitalOceanPaginator('policies')) as $row) {
            $out[] = AlertPolicy::fromArray($row);
        }

        return $out;
    }

    /**
     * The request body for one policy (validated). Exactly one of $dropletIds / $tags should be non-empty.
     *
     * @param list<string>     $emails verified on the DO team
     * @param list<int|string> $dropletIds
     * @param list<string>     $tags
     * @return array<string, mixed>
     */
    public static function body(string $type, float $value, string $window, array $emails, array $dropletIds = [], array $tags = [], string $compare = 'GreaterThan'): array
    {
        if (! isset(self::TYPES[$type])) {
            throw new ValidationException('alert type must be one of: '.implode(', ', array_keys(self::TYPES)));
        }
        if (! in_array($window, self::WINDOWS, true)) {
            throw new ValidationException('window must be one of: '.implode(', ', self::WINDOWS));
        }
        if (! in_array($compare, ['GreaterThan', 'LessThan'], true)) {
            throw new ValidationException('compare must be GreaterThan or LessThan');
        }
        $percent = in_array($type, ['cpu', 'memory', 'disk'], true);
        if ($value <= 0 || ($percent && $value > 100)) {
            throw new ValidationException(sprintf('%s threshold must be %s', $type, $percent ? 'a percentage between 0 and 100' : 'positive'));
        }
        if ($emails === []) {
            throw new ValidationException('an alert policy needs at least one --email');
        }
        foreach ($emails as $email) {
            if (filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
                throw new ValidationException(sprintf('"%s" is not an email address', $email));
            }
        }
        if (($dropletIds === []) === ($tags === [])) {
            throw new ValidationException('give the droplets with --droplet ID[,ID] or --tag NAME (one of the two)');
        }
        $ids = array_map(static fn (int|string $id): string => (string) Validate::id($id, 'droplet id'), $dropletIds);
        $tags = array_map(static fn (string $t): string => Validate::label($t, 'tag'), $tags);
        $scope = $ids !== [] ? 'droplets '.implode(',', $ids) : 'tag '.implode(',', $tags);
        $sign = $compare === 'GreaterThan' ? '>' : '<';

        return [
            'alerts' => ['email' => array_values($emails), 'slack' => []],
            'compare' => $compare,
            'description' => sprintf('workbench: %s %s %s%s for %s on %s', $type, $sign, rtrim(rtrim(number_format($value, 2, '.', ''), '0'), '.'), $percent ? '%' : '', $window, $scope),
            'enabled' => true,
            'entities' => array_values($ids),
            'tags' => array_values($tags),
            'type' => self::TYPES[$type],
            'value' => $value,
            'window' => $window,
        ];
    }

    /**
     * Creates the policies that do not exist yet (matched by description); a no-op when all exist.
     *
     * @param list<array<string, mixed>> $bodies from body()
     * @return PendingAction<list<AlertPolicy>>
     */
    public function apply(array $bodies): PendingAction
    {
        if ($bodies === []) {
            throw new ValidationException('no alert policies to apply');
        }
        $desc = static fn (array $b): string => is_string($b['description'] ?? null) ? $b['description'] : '';
        $existing = array_map(static fn (AlertPolicy $p): string => $p->description, $this->policies());
        $missing = array_values(array_filter($bodies, static fn (array $b): bool => ! in_array($desc($b), $existing, true)));
        /** @var list<AlertPolicy> $none */
        $none = [];
        if ($missing === []) {
            return $this->transport->pending('apply alert policies', implode('; ', array_map($desc, $bodies)), 'NONE', '/v2/monitoring/alerts', [], static fn (): array => $none);
        }
        $run = fn (): array => $this->createAll($missing);

        return $this->transport->pending(
            'apply alert policies',
            sprintf('%d new of %d: %s', count($missing), count($bodies), implode('; ', array_map($desc, $missing))),
            'POST',
            '/v2/monitoring/alerts',
            $missing,
            $run,
            note: 'memory, disk and load alerts need the DO metrics agent on each droplet',
        );
    }

    /**
     * @param list<array<string, mixed>> $bodies
     * @return list<AlertPolicy>
     */
    private function createAll(array $bodies): array
    {
        $out = [];
        foreach ($bodies as $b) {
            $out[] = AlertPolicy::fromArray(Data::map($this->transport->send('POST', '/v2/monitoring/alerts', [], $b)->json, 'policy'));
        }

        return $out;
    }

    /**
     * @param list<string>     $emails
     * @param list<int|string> $dropletIds
     * @param list<string>     $tags
     * @return list<array<string, mixed>>
     */
    public static function standard(array $emails, array $dropletIds = [], array $tags = []): array
    {
        return array_map(static fn (array $s): array => self::body($s[0], (float) $s[1], $s[2], $emails, $dropletIds, $tags), self::STANDARD);
    }

    /** @return PendingAction<bool> */
    public function delete(string $uuid): PendingAction
    {
        $path = '/v2/monitoring/alerts/'.Validate::token($uuid, 'policy uuid');

        return $this->transport->pending('delete alert policy', $uuid, 'DELETE', $path, [], fn (): bool => $this->transport->send('DELETE', $path)->status === 204, destructive: true);
    }
}
