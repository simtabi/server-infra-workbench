<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Security;

use Psr\Log\AbstractLogger;
use Psr\Log\LoggerInterface;

/** PSR-3 decorator: every message and context value passes through the Redactor before the real logger sees it. */
final class RedactingLogger extends AbstractLogger
{
    public function __construct(private readonly LoggerInterface $inner, private readonly Redactor $redactor) {}

    /** @param array<mixed> $context */
    public function log(mixed $level, string|\Stringable $message, array $context = []): void
    {
        $this->inner->log($level, $this->redactor->redact((string) $message), $this->redactor->redactArray($context));
    }
}
