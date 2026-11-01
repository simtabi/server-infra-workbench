<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

final readonly class Operation implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public string $name,
        public string $type,
        public string $status,
        public ?string $zone,
        public string $target,
        public ?string $error,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        $zone = Data::nullableString($d, 'zone');
        $errors = Data::objects($d, 'error.errors');

        return new self(
            Data::string($d, 'name'),
            Data::string($d, 'operationType'),
            Data::string($d, 'status'),
            $zone === null ? null : basename($zone),
            Data::string($d, 'targetLink'),
            $errors === [] ? null : implode('; ', array_map(static fn (array $e): string => Data::string($e, 'message'), $errors)),
        );
    }

    public function isDone(): bool
    {
        return $this->status === 'DONE';
    }
}
