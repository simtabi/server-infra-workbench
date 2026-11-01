<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;

/** DigitalOcean slugs: regions (nyc3), sizes (s-2vcpu-4gb), images (ubuntu-26-04-x64). */
final class Slug
{
    public static function of(string $value, string $what = 'slug'): string
    {
        if (preg_match('/^[a-z0-9][a-z0-9.-]{0,63}$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s "%s" must be a DigitalOcean slug (e.g. nyc3, s-2vcpu-4gb)', $what, substr($value, 0, 80)));
        }

        return $value;
    }
}
