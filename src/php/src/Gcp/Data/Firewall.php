<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

final readonly class Firewall implements \JsonSerializable
{
    use ExportsProperties;

    /**
     * @param list<string> $sourceRanges
     * @param list<string> $allowed      e.g. "tcp:22,5432"
     * @param list<string> $targetTags
     */
    public function __construct(
        public string $name,
        public string $network,
        public string $direction,
        public int $priority,
        public array $sourceRanges,
        public array $allowed,
        public array $targetTags,
        public bool $disabled,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        return new self(
            Data::string($d, 'name'),
            basename(Data::string($d, 'network')),
            Data::string($d, 'direction', 'INGRESS'),
            Data::int($d, 'priority', 1000),
            Data::strings($d, 'sourceRanges'),
            array_map(static function (array $rule): string {
                $ports = Data::strings($rule, 'ports');

                return Data::string($rule, 'IPProtocol').($ports === [] ? '' : ':'.implode(',', $ports));
            }, Data::objects($d, 'allowed')),
            Data::strings($d, 'targetTags'),
            Data::bool($d, 'disabled'),
        );
    }

    /** Ingress open to the whole internet? */
    public function isOpenToWorld(): bool
    {
        return ! $this->disabled && $this->direction === 'INGRESS' && array_intersect($this->sourceRanges, ['0.0.0.0/0', '::/0']) !== [];
    }

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->toArray() + ['openToWorld' => $this->isOpenToWorld()];
    }
}
