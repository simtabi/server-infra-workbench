<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

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
