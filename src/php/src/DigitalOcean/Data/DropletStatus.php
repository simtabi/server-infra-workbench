<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean\Data;

enum DropletStatus: string
{
    case New = 'new';
    case Active = 'active';
    case Off = 'off';
    case Archive = 'archive';
    case Unknown = 'unknown';

    public static function parse(string $value): self
    {
        return self::tryFrom($value) ?? self::Unknown;
    }
}
