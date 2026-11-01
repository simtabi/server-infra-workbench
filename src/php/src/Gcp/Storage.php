<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Item;

/**
 * Cloud Storage buckets, created private by construction: uniform bucket-level access, public access
 * prevention enforced, versioning on. Typical use: off-site backups with a lifecycle rule.
 */
final readonly class Storage
{
    public const array CLASSES = ['STANDARD', 'NEARLINE', 'COLDLINE', 'ARCHIVE'];

    private Endpoint $buckets;

    public function __construct(private Transport $transport, private string $project)
    {
        $this->buckets = new Endpoint($transport, 'bucket', '/b', GcpPaginator::list('items'), [
            'name' => 'name', 'location' => 'location', 'storageClass' => 'storageClass',
            'uniformAccess' => 'iamConfiguration.uniformBucketLevelAccess.enabled',
            'publicAccessPrevention' => 'iamConfiguration.publicAccessPrevention',
            'versioning' => 'versioning.enabled', 'created' => 'timeCreated',
        ], null, ['maxResults' => 1000]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->buckets->list(['project' => $this->project]);
    }

    public function find(string $bucket): Item
    {
        return $this->buckets->get(self::bucket($bucket));
    }

    /**
     * Idempotent by name (bucket names are global: a name owned by another project is a 409).
     *
     * @return PendingAction<Item>
     */
    public function create(string $bucket, string $location = 'US', string $storageClass = 'STANDARD', ?int $deleteAfterDays = null, bool $versioning = true): PendingAction
    {
        $bucket = self::bucket($bucket);
        if (preg_match('/^[A-Za-z0-9-]{2,40}$/', $location) !== 1) {
            throw new ValidationException('location must be a region (us-east1), dual-region or multi-region (US, EU)');
        }
        $storageClass = strtoupper($storageClass);
        if (! in_array($storageClass, self::CLASSES, true)) {
            throw new ValidationException('storage class must be one of '.implode(', ', self::CLASSES));
        }
        foreach ($this->list() as $existing) {
            if ($existing->string('name') === $bucket) {
                return $this->buckets->noop('create bucket', "gs://{$bucket} (exists)", $existing);
            }
        }
        $body = [
            'name' => $bucket, 'location' => strtoupper($location), 'storageClass' => $storageClass,
            'iamConfiguration' => ['uniformBucketLevelAccess' => ['enabled' => true], 'publicAccessPrevention' => 'enforced'],
            'versioning' => ['enabled' => $versioning],
            'labels' => ['managed-by' => 'workbench'],
        ];
        if ($deleteAfterDays !== null) {
            $body['lifecycle'] = ['rule' => [['action' => ['type' => 'Delete'], 'condition' => ['age' => self::days($deleteAfterDays)]]]];
        }

        return $this->transport->pending('create bucket', "gs://{$bucket} in {$location} ({$storageClass})".($deleteAfterDays !== null ? ", objects deleted after {$deleteAfterDays} days" : ''),
            'POST', '/b', $body, fn (): Item => $this->buckets->item($this->transport->send('POST', '/b', ['project' => $this->project], $body)->json),
            note: 'private: uniform access + public access prevention enforced');
    }

    /**
     * Destructive. Cloud Storage refuses unless the bucket is empty (all versions).
     *
     * @return PendingAction<bool>
     */
    public function delete(string $bucket): PendingAction
    {
        return $this->buckets->delete(self::bucket($bucket), "gs://{$bucket}", 'must be empty, including old object versions');
    }

    /** @return list<Item> */
    public function objects(string $bucket, string $prefix = '', int $limit = 1000): array
    {
        $objects = new Endpoint($this->transport, 'object', $this->buckets->path(self::bucket($bucket), 'o'), GcpPaginator::list('items'),
            ['name' => 'name', 'size' => 'size', 'storageClass' => 'storageClass', 'updated' => 'updated']);
        $query = ['maxResults' => min(1000, max(1, $limit))] + ($prefix === '' ? [] : ['prefix' => self::prefix($prefix)]);

        return array_slice($objects->list($query), 0, $limit);
    }

    public static function bucket(string $bucket): string
    {
        if (preg_match('/^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$/', $bucket) !== 1 || str_starts_with($bucket, 'goog')) {
            throw new ValidationException(sprintf('bucket "%s" must be 3-63 lower-case letters, digits, - and _ (no dots here, not starting with goog)', substr($bucket, 0, 80)));
        }

        return $bucket;
    }

    private static function days(int $days): int
    {
        if ($days < 1 || $days > 36_500) {
            throw new ValidationException('retention (days) must be 1 to 36500');
        }

        return $days;
    }

    private static function prefix(string $prefix): string
    {
        if (strlen($prefix) > 1024 || preg_match('/[\x00-\x1f\x7f]/', $prefix) === 1) {
            throw new ValidationException('prefix must be printable, up to 1024 bytes');
        }

        return $prefix;
    }
}
