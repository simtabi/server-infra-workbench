<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Http;

use Psr\Http\Message\ResponseInterface;

/**
 * The quota a provider reports on each response. Header names differ:
 * GitHub/Ploi/Cloudflare x-ratelimit-*, DigitalOcean ratelimit-*. Reset is an epoch second.
 */
final readonly class RateLimit implements \JsonSerializable
{
    /** @param \Closure(): int|null $clock */
    public function __construct(public int $limit, public int $remaining, public ?int $resetAt, private ?\Closure $clock = null) {}

    public static function fromResponse(ResponseInterface $response): ?self
    {
        foreach (['x-ratelimit-', 'ratelimit-'] as $prefix) {
            $remaining = trim($response->getHeaderLine($prefix.'remaining'));
            if ($remaining !== '' && ctype_digit($remaining)) {
                $limit = trim($response->getHeaderLine($prefix.'limit'));
                $reset = trim($response->getHeaderLine($prefix.'reset'));

                return new self(
                    ctype_digit($limit) ? (int) $limit : 0,
                    (int) $remaining,
                    ctype_digit($reset) && (int) $reset > 1_000_000_000 ? (int) $reset : (ctype_digit($reset) ? time() + (int) $reset : null),
                );
            }
        }

        return null;
    }

    /** Seconds until the quota resets (never negative), or null when unknown. */
    public function resetsIn(): ?int
    {
        return $this->resetAt === null ? null : max(0, $this->resetAt - ($this->clock !== null ? ($this->clock)() : time()));
    }

    /** True when less than 10% of the quota is left. */
    public function isLow(): bool
    {
        return $this->limit > 0 && $this->remaining * 10 < $this->limit;
    }

    /** @return array{limit: int, remaining: int, resetAt: int|null} */
    public function jsonSerialize(): array
    {
        return ['limit' => $this->limit, 'remaining' => $this->remaining, 'resetAt' => $this->resetAt];
    }
}
