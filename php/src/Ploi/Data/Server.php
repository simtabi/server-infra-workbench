<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class Server implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public int $id,
        public string $name,
        public string $type,
        public string $status,
        public string $ipAddress,
        public ?string $internalIp,
        public ?string $phpVersion,
        public ?string $databaseVersion,
        public int $sitesCount,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(
            Data::int($d, 'id'),
            Data::string($d, 'name'),
            Data::string($d, 'type'),
            Data::string($d, 'status'),
            Data::string($d, 'ip_address'),
            Data::nullableString($d, 'internal_ip'),
            Data::nullableString($d, 'php_version'),
            Data::nullableString($d, 'mysql_version') ?? Data::nullableString($d, 'database_type'),
            Data::int($d, 'sites_count'),
        );
    }
}
