<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

final readonly class UptimeAlert implements \JsonSerializable
{
    use ExportsProperties;

    /** @param list<string> $emails */
    public function __construct(
        public string $id,
        public string $name,
        public string $type,
        public int $threshold,
        public string $comparison,
        public string $period,
        public array $emails,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(Data::string($d, 'id'), Data::string($d, 'name'), Data::string($d, 'type'), Data::int($d, 'threshold'), Data::string($d, 'comparison'), Data::string($d, 'period'), Data::strings($d, 'notifications.email'));
    }
}
