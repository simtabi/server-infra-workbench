<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Fixtures;

use Simtabi\ServerInfraWorkbench\Http\Sleeper;

final class RecordingSleeper implements Sleeper
{
    /** @var list<int> */
    public array $sleeps = [];

    public function sleep(int $milliseconds): void
    {
        $this->sleeps[] = $milliseconds;
    }
}
