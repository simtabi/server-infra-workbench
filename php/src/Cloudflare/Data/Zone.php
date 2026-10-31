<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Cloudflare\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class Zone implements \JsonSerializable
{
    use ExportsProperties;

    /** @param list<string> $nameServers */
    public function __construct(
        public string $id,
        public string $name,
        public string $status,
        public bool $paused,
        public string $plan,
        public array $nameServers,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(
            Data::string($d, 'id'),
            Data::string($d, 'name'),
            Data::string($d, 'status'),
            Data::bool($d, 'paused'),
            Data::string($d, 'plan.name'),
            Data::strings($d, 'name_servers'),
        );
    }
}
