<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console;

use Psr\Log\AbstractLogger;

/** --verbose: request lines to stderr. Messages arrive already redacted by the transport. */
final class StderrLogger extends AbstractLogger
{
    public function __construct(private readonly Output $output) {}

    /** @param array<mixed> $context */
    public function log(mixed $level, string|\Stringable $message, array $context = []): void
    {
        $text = (string) $message;
        foreach ($context as $key => $value) {
            $text = str_replace('{'.$key.'}', is_scalar($value) ? (string) $value : '…', $text);
        }
        $this->output->error(sprintf('[%s] %s', is_string($level) ? $level : 'log', $text));
    }
}
