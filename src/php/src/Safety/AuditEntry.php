<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Safety;

use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

final readonly class AuditEntry implements \JsonSerializable
{
    use ExportsProperties {
        jsonSerialize as private exported;
    }

    /** @param array<mixed> $payload Already redacted. */
    public function __construct(
        public string $time,
        public string $outcome,
        public string $provider,
        public string $action,
        public string $target,
        public string $method,
        public string $path,
        public array $payload,
        public bool $destructive,
        public string $user,
        public ?string $error = null,
    ) {}

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return array_filter($this->toArray(), static fn (mixed $v): bool => $v !== null);
    }
}
