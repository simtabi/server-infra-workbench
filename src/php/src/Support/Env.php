<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Support;

/**
 * Settings named SIW_* (server-infra-workbench). Before the rename they were VSW_* (vps-server-workbench):
 * an unset SIW_X falls back to VSW_X, and the CLI prints a one-line deprecation notice for each VSW_*
 * it sees. The same holds for the per-user config paths: a file that only exists under the old
 * directory keeps being used. See docs/adr/0014-rename-to-server-infra-workbench.md.
 */
final class Env
{
    public const string PREFIX = 'SIW_';

    public const string LEGACY_PREFIX = 'VSW_';

    public const string NAME = 'server-infra-workbench';

    public const string LEGACY_NAME = 'vps-server-workbench';

    /**
     * SIW_X from $env (default getenv()), else the pre-rename VSW_X; null when both are unset or empty.
     *
     * @param array<string, string>|null $env
     */
    public static function get(string $name, ?array $env = null): ?string
    {
        $value = self::raw($name, $env);
        if ($value === null && str_starts_with($name, self::PREFIX)) {
            $value = self::raw(self::legacyName($name), $env);
        }

        return $value;
    }

    /** SIW_X -> VSW_X (any other name is returned as is). */
    public static function legacyName(string $name): string
    {
        return str_starts_with($name, self::PREFIX) ? self::LEGACY_PREFIX.substr($name, strlen(self::PREFIX)) : $name;
    }

    /**
     * $env with every VSW_X copied to SIW_X where SIW_X is unset: for code that reads an env array.
     *
     * @param array<string, string> $env
     * @return array<string, string>
     */
    public static function withFallbacks(array $env): array
    {
        foreach ($env as $key => $value) {
            if (str_starts_with($key, self::LEGACY_PREFIX)) {
                $env[self::PREFIX.substr($key, strlen(self::LEGACY_PREFIX))] ??= $value;
            }
        }

        return $env;
    }

    /**
     * The pre-rename VSW_* names that are set (non-empty), sorted: what the deprecation notice lists.
     *
     * @param array<string, string>|null $env
     * @return list<string>
     */
    public static function legacyInUse(?array $env = null): array
    {
        $names = [];
        foreach ($env ?? getenv() as $key => $value) {
            if (str_starts_with((string) $key, self::LEGACY_PREFIX) && is_string($value) && $value !== '') {
                $names[] = (string) $key;
            }
        }
        sort($names);

        return $names;
    }

    /**
     * A per-user path under the new name, or the same path under the old name when only that one exists
     * (credentials and keys.json written before the rename keep working without a move).
     */
    public static function userPath(string $home, string $relative): string
    {
        $new = $home.'/'.str_replace('{name}', self::NAME, $relative);
        $old = $home.'/'.str_replace('{name}', self::LEGACY_NAME, $relative);

        return ! file_exists($new) && file_exists($old) ? $old : $new;
    }

    /** @param array<string, string>|null $env */
    private static function raw(string $name, ?array $env): ?string
    {
        $value = $env !== null ? ($env[$name] ?? null) : getenv($name);

        return is_string($value) && $value !== '' ? $value : null;
    }
}
