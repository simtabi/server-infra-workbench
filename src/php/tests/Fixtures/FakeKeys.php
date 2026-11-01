<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Fixtures;

/** Structurally valid, made-up public keys (random-looking bytes from a seed; no private half exists). */
final class FakeKeys
{
    public static function ed25519(string $comment, int $seed = 1): string
    {
        $raw = substr(hash('sha256', 'vsw-fake-key-'.$seed, true), 0, 32);
        $blob = pack('N', 11).'ssh-ed25519'.pack('N', 32).$raw;

        return trim('ssh-ed25519 '.base64_encode($blob).' '.$comment);
    }

    public static function fingerprint(string $line): string
    {
        $parts = explode(' ', $line);

        return 'SHA256:'.rtrim(base64_encode(hash('sha256', (string) base64_decode($parts[1], true), true)), '=');
    }
}
