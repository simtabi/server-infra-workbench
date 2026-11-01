<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Http;

/** Injectable so tests never actually sleep. */
interface Sleeper
{
    public function sleep(int $milliseconds): void;
}
