<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Fixtures;

use Psr\Log\AbstractLogger;

final class MemoryLogger extends AbstractLogger
{
    /** @var list<string> */
    public array $lines = [];

    /** @param array<mixed> $context */
    public function log(mixed $level, string|\Stringable $message, array $context = []): void
    {
        $text = (string) $message;
        foreach ($context as $key => $value) {
            $text = str_replace('{'.$key.'}', is_scalar($value) ? (string) $value : json_encode($value, JSON_THROW_ON_ERROR), $text);
        }
        $this->lines[] = (is_string($level) ? $level : '?').' '.$text.' '.json_encode($context, JSON_THROW_ON_ERROR);
    }

    public function all(): string
    {
        return implode("\n", $this->lines);
    }
}
