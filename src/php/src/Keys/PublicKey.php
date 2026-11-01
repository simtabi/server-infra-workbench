<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Keys;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;

/**
 * One OpenSSH public key line: [options] type base64 [comment]. Keys are compared by their key material
 * (the base64 body), so a key is recognised even when its options or comment differ.
 */
final readonly class PublicKey
{
    public const array TYPES = [
        'ssh-rsa', 'ssh-dss', 'ssh-ed25519',
        'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521',
        'sk-ssh-ed25519@openssh.com', 'sk-ecdsa-sha2-nistp256@openssh.com',
    ];

    private function __construct(public string $options, public string $type, public string $body, public string $comment) {}

    /** Null when the line is blank, a comment, or not a well-formed key. */
    public static function tryParse(string $line): ?self
    {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#')) {
            return null;
        }
        $tokens = preg_split('/\s+/', $line);
        if ($tokens === false) {
            return null;
        }
        foreach ($tokens as $i => $token) {
            if (! in_array($token, self::TYPES, true)) {
                continue;
            }
            $body = $tokens[$i + 1] ?? '';
            if (strlen($body) < 20) {
                return null;
            }
            $blob = base64_decode($body, true);
            // the blob starts with the key type as an SSH string: uint32 length + name
            if ($blob === false || strlen($blob) < 4) {
                return null;
            }
            $len = unpack('N', substr($blob, 0, 4));
            if (! is_array($len) || ! is_int($len[1] ?? null) || substr($blob, 4, $len[1]) !== $token) {
                return null;
            }

            return new self(implode(' ', array_slice($tokens, 0, $i)), $token, $body, implode(' ', array_slice($tokens, $i + 2)));
        }

        return null;
    }

    public static function parse(string $line): self
    {
        return self::tryParse($line) ?? throw new ValidationException("that doesn't look like a valid OpenSSH public key (expected e.g. \"ssh-ed25519 AAAA... you@host\")");
    }

    public static function isValid(string $line): bool
    {
        return self::tryParse($line) !== null;
    }

    public static function same(string $a, string $b): bool
    {
        $ka = self::tryParse($a);
        $kb = self::tryParse($b);

        return $ka !== null && $kb !== null && $ka->body === $kb->body;
    }

    /** "SHA256:..." exactly like ssh-keygen -l. */
    public function fingerprint(): string
    {
        return 'SHA256:'.rtrim(base64_encode(hash('sha256', (string) base64_decode($this->body, true), true)), '=');
    }

    /** "MD5:aa:bb:..." (the form DigitalOcean shows). */
    public function md5(): string
    {
        return implode(':', str_split(md5((string) base64_decode($this->body, true)), 2));
    }

    public function label(): string
    {
        return $this->comment !== '' ? $this->comment : $this->type;
    }

    /** type + body + comment, without options: the form provider dashboards accept. */
    public function line(): string
    {
        return trim($this->type.' '.$this->body.' '.$this->comment);
    }
}
