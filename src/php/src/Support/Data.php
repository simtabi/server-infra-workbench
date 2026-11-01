<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Support;

/**
 * Typed reads from decoded JSON. Providers return loosely typed arrays; DTOs read them through
 * here so a missing or mistyped field becomes a default instead of a TypeError deep in a constructor.
 */
final class Data
{
    /** @param array<mixed> $data */
    public static function get(array $data, string $path): mixed
    {
        $value = $data;
        foreach (explode('.', $path) as $key) {
            if (! is_array($value) || ! array_key_exists($key, $value)) {
                return null;
            }
            $value = $value[$key];
        }

        return $value;
    }

    /** @param array<mixed> $data */
    public static function string(array $data, string $path, string $default = ''): string
    {
        $value = self::get($data, $path);

        return is_string($value) || is_int($value) || is_float($value) ? (string) $value : $default;
    }

    /** @param array<mixed> $data */
    public static function nullableString(array $data, string $path): ?string
    {
        $value = self::get($data, $path);

        return is_string($value) || is_int($value) ? (string) $value : null;
    }

    /** @param array<mixed> $data */
    public static function int(array $data, string $path, int $default = 0): int
    {
        $value = self::get($data, $path);

        return is_int($value) ? $value : (is_string($value) && preg_match('/^-?\d+$/', $value) === 1 ? (int) $value : $default);
    }

    /** @param array<mixed> $data */
    public static function bool(array $data, string $path, bool $default = false): bool
    {
        $value = self::get($data, $path);

        return is_bool($value) ? $value : $default;
    }

    /**
     * @param array<mixed> $data
     * @return array<string, mixed>
     */
    public static function map(array $data, string $path): array
    {
        $value = self::get($data, $path);
        if (! is_array($value)) {
            return [];
        }
        $out = [];
        foreach ($value as $k => $v) {
            $out[(string) $k] = $v;
        }

        return $out;
    }

    /**
     * A list of objects (arrays); anything else in the list is dropped.
     *
     * @param array<mixed> $data
     * @return list<array<string, mixed>>
     */
    public static function objects(array $data, string $path): array
    {
        $value = self::get($data, $path);
        if (! is_array($value)) {
            return [];
        }
        $out = [];
        foreach ($value as $item) {
            if (is_array($item)) {
                $row = [];
                foreach ($item as $k => $v) {
                    $row[(string) $k] = $v;
                }
                $out[] = $row;
            }
        }

        return $out;
    }

    /**
     * @param array<mixed> $data
     * @return list<string>
     */
    public static function strings(array $data, string $path): array
    {
        $value = self::get($data, $path);
        if (! is_array($value)) {
            return [];
        }

        return array_values(array_filter(array_map(
            static fn (mixed $v): ?string => is_string($v) ? $v : null,
            $value,
        ), static fn (?string $v): bool => $v !== null));
    }
}
