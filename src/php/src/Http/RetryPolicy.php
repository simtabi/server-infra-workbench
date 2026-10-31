<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

/**
 * When and how long to back off. Retries 429 always, and 5xx / network errors only for idempotent
 * methods (GET, HEAD, PUT, DELETE) so a POST is never sent twice. Retry-After wins over backoff.
 */
final class RetryPolicy
{
    private function __construct(
        private readonly int $maxAttempts,
        private readonly int $baseDelayMs,
        private readonly int $maxDelayMs,
        private readonly int $maxRetryAfterMs,
        private readonly bool $jitter,
    ) {}

    public static function default(): self
    {
        return new self(4, 500, 20_000, 120_000, true);
    }

    public static function none(): self
    {
        return new self(1, 0, 0, 0, false);
    }

    public function withMaxAttempts(int $attempts): self
    {
        return new self(max(1, $attempts), $this->baseDelayMs, $this->maxDelayMs, $this->maxRetryAfterMs, $this->jitter);
    }

    public function withBackoff(int $baseDelayMs, int $maxDelayMs): self
    {
        return new self($this->maxAttempts, max(0, $baseDelayMs), max($baseDelayMs, $maxDelayMs), $this->maxRetryAfterMs, $this->jitter);
    }

    public function withJitter(bool $jitter): self
    {
        return new self($this->maxAttempts, $this->baseDelayMs, $this->maxDelayMs, $this->maxRetryAfterMs, $jitter);
    }

    public function maxAttempts(): int
    {
        return $this->maxAttempts;
    }

    public function shouldRetry(int $attempt, int $status, bool $idempotent): bool
    {
        if ($attempt >= $this->maxAttempts) {
            return false;
        }

        return $status === 429 || ($idempotent && in_array($status, [500, 502, 503, 504], true));
    }

    public function shouldRetryNetworkError(int $attempt, bool $idempotent): bool
    {
        return $idempotent && $attempt < $this->maxAttempts;
    }

    /** Delay before the next attempt; $attempt is the one that just failed (1-based). */
    public function delayMs(int $attempt, ?int $retryAfterSeconds = null): int
    {
        if ($retryAfterSeconds !== null) {
            return min(max(0, $retryAfterSeconds) * 1000, $this->maxRetryAfterMs);
        }
        $delay = min($this->baseDelayMs * (2 ** max(0, $attempt - 1)), $this->maxDelayMs);

        return $this->jitter && $delay > 1 ? random_int(intdiv($delay, 2), $delay) : $delay;
    }
}
