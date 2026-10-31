<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

use Simtabi\VpsServerWorkbench\Exception\TimeoutException;

/**
 * Polls until a condition holds. Time is counted in slept intervals, so tests with a fake Sleeper are exact.
 * When the sleeper is also a WaitObserver (the console's ProgressSleeper), it hears about every poll.
 */
final class Waiter
{
    /**
     * @template T
     *
     * @param \Closure(): T         $refresh
     * @param \Closure(T): bool     $done
     * @return T
     */
    public static function until(Sleeper $sleeper, \Closure $refresh, \Closure $done, int $timeoutSeconds, int $pollSeconds, string $what): mixed
    {
        $pollSeconds = max(1, $pollSeconds);
        $observer = $sleeper instanceof WaitObserver ? $sleeper : null;
        for ($waited = 0; ; $waited += $pollSeconds) {
            $current = $refresh();
            if ($done($current)) {
                $observer?->finished($what, $waited, true);

                return $current;
            }
            if ($waited + $pollSeconds > $timeoutSeconds) {
                $observer?->finished($what, $waited, false);

                throw new TimeoutException(sprintf('%s did not finish within %d s', $what, $timeoutSeconds));
            }
            $observer?->waiting($what, $waited, $timeoutSeconds);
            $sleeper->sleep($pollSeconds * 1000);
        }
    }
}
