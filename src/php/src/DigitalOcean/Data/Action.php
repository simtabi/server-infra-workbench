<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

final readonly class Action implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public int $id,
        public ActionStatus $status,
        public string $type,
        public int $resourceId,
        public string $startedAt,
        public ?string $completedAt,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(
            Data::int($d, 'id'),
            ActionStatus::parse(Data::string($d, 'status')),
            Data::string($d, 'type'),
            Data::int($d, 'resource_id'),
            Data::string($d, 'started_at'),
            Data::nullableString($d, 'completed_at'),
        );
    }
}
