<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

final readonly class Snapshot implements \JsonSerializable
{
    use ExportsProperties;

    /** @param list<string> $regions */
    public function __construct(
        public string $id,
        public string $name,
        public string $resourceId,
        public string $resourceType,
        public float $sizeGb,
        public int $minDiskSizeGb,
        public array $regions,
        public string $createdAt,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        $size = Data::get($d, 'size_gigabytes');

        return new self(
            Data::string($d, 'id'),
            Data::string($d, 'name'),
            Data::string($d, 'resource_id'),
            Data::string($d, 'resource_type'),
            is_int($size) || is_float($size) ? (float) $size : 0.0,
            Data::int($d, 'min_disk_size'),
            Data::strings($d, 'regions'),
            Data::string($d, 'created_at'),
        );
    }
}
