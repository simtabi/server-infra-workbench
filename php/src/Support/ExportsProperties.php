<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Support;

/** JSON form of a readonly DTO: its public properties, enums as their values. */
trait ExportsProperties
{
    /** @return array<string, mixed> */
    public function toArray(): array
    {
        $out = [];
        foreach (get_object_vars($this) as $key => $value) {
            $out[(string) $key] = $value instanceof \BackedEnum ? $value->value : $value;
        }

        return $out;
    }

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->toArray();
    }
}
