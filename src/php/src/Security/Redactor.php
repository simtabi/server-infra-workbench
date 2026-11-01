<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Security;

/**
 * Removes secrets from anything about to be logged, audited, printed or put in an exception message.
 * Two layers: the exact values of known secrets, and patterns for credential-shaped text.
 */
final class Redactor
{
    public const string MASK = '***';

    private const array PATTERNS = [
        '/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s',
        '/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i',
        '/\bdop_v1_[a-f0-9]{64}\b/',
        '/\bya29\.[A-Za-z0-9._-]+/',
        '/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,255}\b/',
        '/\bgithub_pat_[A-Za-z0-9_]{22,255}\b/',
        '/("?(?:[a-z_]*(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|authorization|assertion|client_secret))"?\s*[:=]\s*"?)(?!(?:Bearer|Basic)\s)([^"\s,&}]+)/i',
    ];

    /** @var list<string> */
    private array $secrets = [];

    public function withSecret(Secret|string ...$secrets): self
    {
        $clone = clone $this;
        foreach ($secrets as $secret) {
            $value = $secret instanceof Secret ? $secret->reveal() : $secret;
            if (strlen($value) >= 6 && ! in_array($value, $clone->secrets, true)) {
                $clone->secrets[] = $value;
            }
        }
        usort($clone->secrets, static fn (string $a, string $b): int => strlen($b) <=> strlen($a));

        return $clone;
    }

    public function redact(string $text): string
    {
        foreach ($this->secrets as $secret) {
            $text = str_replace([$secret, rawurlencode($secret)], self::MASK, $text);
        }
        foreach (self::PATTERNS as $i => $pattern) {
            $text = (string) preg_replace($pattern, $i === 4 ? '$1'.self::MASK : ($i === 1 ? '$1 '.self::MASK : self::MASK), $text);
        }

        return $text;
    }

    /**
     * @param array<mixed> $data
     * @return array<mixed>
     */
    public function redactArray(array $data): array
    {
        $out = [];
        foreach ($data as $key => $value) {
            if (is_string($key) && preg_match('/token|secret|password|passwd|api[_-]?key|private[_-]?key|authorization|assertion/i', $key) === 1) {
                $out[$key] = self::MASK;

                continue;
            }
            $out[$key] = match (true) {
                is_array($value) => $this->redactArray($value),
                is_string($value) => $this->redact($value),
                $value instanceof Secret => self::MASK,
                default => $value,
            };
        }

        return $out;
    }
}
