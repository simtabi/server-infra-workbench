<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class UptimeCheck implements \JsonSerializable
{
    use ExportsProperties;

    /** @param list<string> $regions */
    public function __construct(
        public string $id,
        public string $name,
        public string $type,
        public string $target,
        public array $regions,
        public bool $enabled,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(Data::string($d, 'id'), Data::string($d, 'name'), Data::string($d, 'type'), Data::string($d, 'target'), Data::strings($d, 'regions'), Data::bool($d, 'enabled', true));
    }
}
