<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console\Commands;

use Simtabi\ServerInfraWorkbench\Console\Input;

/** One `workbench <area>` command. Returns the process exit code. */
interface Command
{
    public function run(Input $in): int;
}
