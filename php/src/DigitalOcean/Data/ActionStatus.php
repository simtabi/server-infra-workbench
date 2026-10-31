<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean\Data;

enum ActionStatus: string
{
    case InProgress = 'in-progress';
    case Completed = 'completed';
    case Errored = 'errored';

    public static function parse(string $value): self
    {
        return self::tryFrom($value) ?? self::InProgress;
    }

    public function isFinished(): bool
    {
        return $this !== self::InProgress;
    }
}
