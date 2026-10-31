<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class Site implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public int $id,
        public int $serverId,
        public string $domain,
        public string $status,
        public string $projectType,
        public ?string $phpVersion,
        public string $webDirectory,
        public ?string $lastDeployAt,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(
            Data::int($d, 'id'),
            Data::int($d, 'server_id'),
            Data::string($d, 'domain'),
            Data::string($d, 'status'),
            Data::string($d, 'project_type'),
            Data::nullableString($d, 'php_version'),
            Data::string($d, 'web_directory'),
            Data::nullableString($d, 'last_deploy_at'),
        );
    }
}
