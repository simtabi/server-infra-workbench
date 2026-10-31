<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Health;

use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class HealthResult implements \JsonSerializable
{
    use ExportsProperties;

    /** @param list<string> $problems */
    public function __construct(
        public string $url,
        public bool $ok,
        public ?int $status,
        public int $ms,
        public array $problems,
    ) {}
}
