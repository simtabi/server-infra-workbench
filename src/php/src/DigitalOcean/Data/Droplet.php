<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class Droplet implements \JsonSerializable
{
    use ExportsProperties;

    /** @param list<string> $tags */
    public function __construct(
        public int $id,
        public string $name,
        public DropletStatus $status,
        public string $region,
        public string $size,
        public int $memoryMb,
        public int $vcpus,
        public int $diskGb,
        public ?string $publicIpv4,
        public ?string $privateIpv4,
        public array $tags,
        public string $createdAt,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        $ip = static function (string $type) use ($d): ?string {
            foreach (Data::objects($d, 'networks.v4') as $net) {
                if (Data::string($net, 'type') === $type) {
                    return Data::nullableString($net, 'ip_address');
                }
            }

            return null;
        };

        return new self(
            Data::int($d, 'id'),
            Data::string($d, 'name'),
            DropletStatus::parse(Data::string($d, 'status')),
            Data::string($d, 'region.slug'),
            Data::string($d, 'size_slug', Data::string($d, 'size.slug')),
            Data::int($d, 'memory'),
            Data::int($d, 'vcpus'),
            Data::int($d, 'disk'),
            $ip('public'),
            $ip('private'),
            Data::strings($d, 'tags'),
            Data::string($d, 'created_at'),
        );
    }
}
