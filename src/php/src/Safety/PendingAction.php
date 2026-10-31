<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Safety;

use Simtabi\VpsServerWorkbench\Security\Redactor;

/**
 * A write that has been described but not sent. Nothing reaches the provider until confirm().
 * plan() is the dry run: it shows exactly what would be sent and records that in the audit log.
 *
 * @template T
 */
final class PendingAction implements \JsonSerializable
{
    private bool $done = false;

    /**
     * @param array<mixed> $payload
     * @param \Closure(): T $run
     */
    public function __construct(
        private readonly string $provider,
        private readonly string $action,
        private readonly string $target,
        private readonly string $method,
        private readonly string $path,
        private readonly array $payload,
        private readonly \Closure $run,
        private readonly AuditLog $audit,
        private readonly Redactor $redactor,
        private readonly bool $destructive = false,
        private readonly ?string $note = null,
    ) {}

    public function isDestructive(): bool
    {
        return $this->destructive;
    }

    /** True when the provider is already in the requested state, so confirm() sends nothing. */
    public function isNoop(): bool
    {
        return $this->method === 'NONE';
    }

    public function describe(): string
    {
        return sprintf(
            '%s: %s %s%s%s',
            $this->provider,
            $this->action,
            $this->target,
            $this->isNoop() ? ' (no change needed)' : sprintf(' (%s %s)', $this->method, $this->path),
            $this->destructive ? ' [DESTRUCTIVE]' : '',
        );
    }

    /**
     * The dry run. Sends nothing.
     *
     * @return array{provider: string, action: string, target: string, method: string, path: string, payload: array<mixed>, destructive: bool, note: string|null}
     */
    public function plan(): array
    {
        $this->record('dry-run');

        return $this->toArray();
    }

    /**
     * Sends the request. Runs at most once.
     *
     * @return T
     */
    public function confirm(): mixed
    {
        if ($this->done) {
            throw new \LogicException('this action was already confirmed; build a new one to repeat it');
        }
        $this->done = true;
        $this->record('confirmed');

        try {
            $result = ($this->run)();
        } catch (\Throwable $e) {
            $this->record('failed', $this->redactor->redact($e->getMessage()));

            throw $e;
        }
        $this->record('succeeded');

        return $result;
    }

    /** @return array{provider: string, action: string, target: string, method: string, path: string, payload: array<mixed>, destructive: bool, note: string|null} */
    public function toArray(): array
    {
        return [
            'provider' => $this->provider,
            'action' => $this->action,
            'target' => $this->target,
            'method' => $this->method,
            'path' => $this->path,
            'payload' => $this->redactor->redactArray($this->payload),
            'destructive' => $this->destructive,
            'note' => $this->note,
        ];
    }

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->toArray();
    }

    private function record(string $outcome, ?string $error = null): void
    {
        $user = getenv('USER');
        $this->audit->record(new AuditEntry(
            gmdate('Y-m-d\TH:i:s\Z'),
            $outcome,
            $this->provider,
            $this->action,
            $this->target,
            $this->method,
            $this->path,
            $this->redactor->redactArray($this->payload),
            $this->destructive,
            is_string($user) ? $user : 'unknown',
            $error,
        ));
    }
}
