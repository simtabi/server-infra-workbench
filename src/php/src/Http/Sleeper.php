<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

/** Injectable so tests never actually sleep. */
interface Sleeper
{
    public function sleep(int $milliseconds): void;
}
