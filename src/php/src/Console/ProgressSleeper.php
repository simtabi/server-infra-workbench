<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

use Simtabi\VpsServerWorkbench\Http\Sleeper;
use Simtabi\VpsServerWorkbench\Http\WaitObserver;

/** Decorates the real (or a test) Sleeper so every Waiter poll shows up as progress. */
final readonly class ProgressSleeper implements Sleeper, WaitObserver
{
    public function __construct(private Sleeper $inner, private Progress $progress) {}

    public function sleep(int $milliseconds): void
    {
        $this->inner->sleep($milliseconds);
    }

    public function waiting(string $what, int $waitedSeconds, int $timeoutSeconds): void
    {
        $this->progress->waiting($what, $waitedSeconds, $timeoutSeconds);
    }

    public function finished(string $what, int $waitedSeconds, bool $ok): void
    {
        if ($waitedSeconds > 0 || ! $ok) {
            $this->progress->finished($what, $waitedSeconds, $ok);
        }
    }
}
