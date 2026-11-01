<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Support;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;

/**
 * Input validation shared by the clients and the CLI. Everything that ends up in a URL path is checked
 * here first, so a value can never change which endpoint is called.
 */
final class Validate
{
    public static function id(int|string $value, string $what = 'id'): int
    {
        if (is_int($value) ? $value < 1 : preg_match('/^[1-9]\d{0,18}$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s must be a positive integer, got "%s"', $what, self::show($value)));
        }

        return (int) $value;
    }

    /** Cloudflare / DigitalOcean style hex or uuid identifiers. */
    public static function token(string $value, string $what = 'id'): string
    {
        if (preg_match('/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s "%s" is not a valid identifier', $what, self::show($value)));
        }

        return $value;
    }

    /**
     * One URL path segment that is not a plain number or simple token: GitHub owner/repo names, release
     * tags, workflow file names, Spaces access keys, bucket names. Never empty, never "." or "..".
     */
    public static function segment(string $value, string $what = 'name', int $max = 255): string
    {
        if ($value === '.' || $value === '..' || preg_match('/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,'.($max - 1).'}$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s "%s" may only contain letters, digits, _ . - (max %d)', $what, self::show($value), $max));
        }

        return $value;
    }

    /** An IPv4/IPv6 address or CIDR block. */
    public static function cidr(string $value, string $what = 'address'): string
    {
        [$ip, $bits] = array_pad(explode('/', $value, 2), 2, null);
        $v4 = filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false;
        $v6 = ! $v4 && filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false;
        if ((! $v4 && ! $v6) || ($bits !== null && (! ctype_digit($bits) || (int) $bits > ($v4 ? 32 : 128)))) {
            throw new ValidationException(sprintf('%s "%s" is not an IP address or CIDR block', $what, self::show($value)));
        }

        return $value;
    }

    public static function domain(string $value, string $what = 'domain'): string
    {
        $value = strtolower(rtrim($value, '.'));
        if (strlen($value) > 253
            || preg_match('/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s "%s" is not a valid domain name', $what, self::show($value)));
        }

        return $value;
    }

    /** A DNS record name: a domain, optionally starting with "*." or "_service." labels, or "@". */
    public static function dnsName(string $value): string
    {
        if ($value === '@') {
            return $value;
        }
        $name = strtolower(rtrim($value, '.'));
        $label = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';
        if (strlen($name) > 253 || preg_match('/^(?:\*\.)?(?:_[a-z0-9-]+\.)*'.$label.'(?:\.'.$label.')*$|^\*$/', $name) !== 1) {
            throw new ValidationException(sprintf('record name "%s" is not a valid DNS name', self::show($value)));
        }

        return $name;
    }

    /** Google Cloud resource names (RFC 1035 labels). */
    public static function gcpName(string $value, string $what = 'name'): string
    {
        if (preg_match('/^[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s "%s" must be lower-case letters, digits and dashes (RFC 1035)', $what, self::show($value)));
        }

        return $value;
    }

    /** Free-form display names (snapshot names, labels): printable, no control characters. */
    public static function label(string $value, string $what = 'name', int $max = 255): string
    {
        if ($value === '' || strlen($value) > $max || preg_match('/^[A-Za-z0-9][A-Za-z0-9 ._:@-]*$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s "%s" may only contain letters, digits, space and . _ : @ - (max %d)', $what, self::show($value), $max));
        }

        return $value;
    }

    public static function range(int $value, int $min, int $max, string $what): int
    {
        if ($value < $min || $value > $max) {
            throw new ValidationException(sprintf('%s must be between %d and %d, got %d', $what, $min, $max, $value));
        }

        return $value;
    }

    private static function show(int|string $value): string
    {
        $value = (string) $value;

        return strlen($value) > 80 ? substr($value, 0, 77).'...' : (preg_replace('/[^\x20-\x7e]/', '?', $value) ?? '');
    }
}
