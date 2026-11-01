<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Support;

/**
 * A provider resource reduced to the fields the workbench shows. Used for the long tail of resources
 * (volumes, VPCs, buckets, releases, ...) where a dedicated DTO would only repeat the field list.
 * Core resources with behaviour (droplets, DNS records, ...) keep their typed DTOs.
 */
final readonly class Item implements \JsonSerializable
{
    /** @param array<string, mixed> $data */
    public function __construct(public array $data) {}

    /**
     * @param array<mixed>                                              $row
     * @param array<string, string|\Closure(array<mixed>): mixed>       $fields output key => dot path in $row, or a closure
     */
    public static function of(array $row, array $fields): self
    {
        $out = [];
        foreach ($fields as $key => $path) {
            $out[$key] = $path instanceof \Closure ? $path($row) : Data::get($row, $path);
        }

        return new self($out);
    }

    public function get(string $key): mixed
    {
        return $this->data[$key] ?? null;
    }

    public function string(string $key): string
    {
        return Data::string($this->data, $key);
    }

    public function int(string $key): int
    {
        return Data::int($this->data, $key);
    }

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->data;
    }
}
