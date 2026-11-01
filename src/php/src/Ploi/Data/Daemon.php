<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Ploi\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

/** A supervisor-managed process Ploi keeps running (queue workers, Horizon, Node servers). */
final readonly class Daemon implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public int $id,
        public string $command,
        public string $systemUser,
        public int $processes,
        public string $directory,
        public string $status,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(
            Data::int($d, 'id'),
            Data::string($d, 'command'),
            Data::string($d, 'system_user'),
            Data::int($d, 'processes', 1),
            Data::string($d, 'directory'),
            Data::string($d, 'status'),
        );
    }
}
