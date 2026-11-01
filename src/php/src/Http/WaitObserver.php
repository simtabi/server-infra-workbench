<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Http;

/**
 * Told about each poll of a long wait (a resize, a snapshot). A Sleeper may implement it too: Waiter
 * reports to the sleeper it was given, so progress output needs no extra wiring through the API clients.
 */
interface WaitObserver
{
    public function waiting(string $what, int $waitedSeconds, int $timeoutSeconds): void;

    public function finished(string $what, int $waitedSeconds, bool $ok): void;
}
