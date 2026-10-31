<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class Snapshot implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public string $id,
        public string $name,
        public string $status,
        public string $sourceDisk,
        public int $diskSizeGb,
        public int $storageBytes,
        public string $createdAt,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(
            Data::string($d, 'id'),
            Data::string($d, 'name'),
            Data::string($d, 'status'),
            basename(Data::string($d, 'sourceDisk')),
            Data::int($d, 'diskSizeGb'),
            Data::int($d, 'storageBytes'),
            Data::string($d, 'creationTimestamp'),
        );
    }
}
