<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

/** A DigitalOcean Monitoring alert policy (CPU, memory, disk, load ... on droplets or tags). */
final readonly class AlertPolicy implements \JsonSerializable
{
    use ExportsProperties;

    /**
     * @param list<string> $entities droplet ids
     * @param list<string> $tags
     * @param list<string> $emails
     */
    public function __construct(
        public string $uuid,
        public string $type,
        public string $description,
        public string $compare,
        public float $value,
        public string $window,
        public array $entities,
        public array $tags,
        public array $emails,
        public bool $enabled,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        $value = Data::get($d, 'value');

        return new self(
            Data::string($d, 'uuid'),
            Data::string($d, 'type'),
            Data::string($d, 'description'),
            Data::string($d, 'compare'),
            is_int($value) || is_float($value) ? (float) $value : 0.0,
            Data::string($d, 'window'),
            array_map(strval(...), array_values(array_filter(is_array($d['entities'] ?? null) ? $d['entities'] : [], is_scalar(...)))),
            Data::strings($d, 'tags'),
            Data::strings($d, 'alerts.email'),
            Data::bool($d, 'enabled', true),
        );
    }
}
