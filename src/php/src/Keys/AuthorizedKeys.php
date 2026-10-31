<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Keys;

/** Pure text operations on an authorized_keys file. Comments, options and unknown lines are preserved. */
final class AuthorizedKeys
{
    /** @return list<array{line: string, key: PublicKey}> the real key lines, in file order */
    public static function entries(string $text): array
    {
        $out = [];
        foreach (self::lines($text) as $line) {
            $key = PublicKey::tryParse($line);
            if ($key !== null) {
                $out[] = ['line' => rtrim($line), 'key' => $key];
            }
        }

        return $out;
    }

    public static function count(string $text): int
    {
        return count(self::entries($text));
    }

    /** @return array{0: string, 1: bool} new text, and whether the key was added (false = already there) */
    public static function add(string $text, string $line): array
    {
        $new = PublicKey::parse($line);
        foreach (self::entries($text) as $entry) {
            if ($entry['key']->body === $new->body) {
                return [$text, false];
            }
        }
        $base = rtrim($text, "\n");

        return [($base === '' ? '' : $base."\n").trim($line)."\n", true];
    }

    /** @return array{0: string, 1: int} new text, and how many lines carried that key material */
    public static function remove(string $text, PublicKey $key): array
    {
        $kept = [];
        $removed = 0;
        foreach (self::lines(rtrim($text, "\n")) as $line) {
            if (PublicKey::tryParse($line)?->body === $key->body) {
                $removed++;

                continue;
            }
            $kept[] = $line;
        }
        $joined = implode("\n", $kept);

        return [$joined === '' ? '' : $joined."\n", $removed];
    }

    /** @return list<string> */
    private static function lines(string $text): array
    {
        $lines = preg_split('/\R/', $text);

        return $lines === false ? [] : $lines;
    }

    /**
     * Find an entry by 1-based number, SHA256 fingerprint, or exact comment.
     *
     * @return array{line: string, key: PublicKey}|null
     */
    public static function select(string $text, string $selector): ?array
    {
        $entries = self::entries($text);
        if (ctype_digit($selector)) {
            return $entries[(int) $selector - 1] ?? null;
        }
        $matches = array_values(array_filter($entries, static fn (array $e): bool => $e['key']->fingerprint() === $selector || $e['key']->comment === $selector));

        return count($matches) === 1 ? $matches[0] : null;
    }
}
