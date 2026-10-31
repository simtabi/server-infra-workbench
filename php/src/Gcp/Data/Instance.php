<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class Instance implements \JsonSerializable
{
    use ExportsProperties;

    /**
     * @param list<string>          $disks
     * @param array<string, mixed>  $labels
     */
    public function __construct(
        public string $id,
        public string $name,
        public string $zone,
        public InstanceStatus $status,
        public string $machineType,
        public ?string $internalIp,
        public ?string $externalIp,
        public array $disks,
        public array $labels,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        $nic = Data::objects($d, 'networkInterfaces')[0] ?? [];
        $nat = Data::objects($nic, 'accessConfigs')[0] ?? [];

        return new self(
            Data::string($d, 'id'),
            Data::string($d, 'name'),
            basename(Data::string($d, 'zone')),
            InstanceStatus::parse(Data::string($d, 'status')),
            basename(Data::string($d, 'machineType')),
            Data::nullableString($nic, 'networkIP'),
            Data::nullableString($nat, 'natIP'),
            array_map(static fn (array $disk): string => basename(Data::string($disk, 'source')), Data::objects($d, 'disks')),
            Data::map($d, 'labels'),
        );
    }
}
