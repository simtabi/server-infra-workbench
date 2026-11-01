<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console\Commands;

use Simtabi\VpsServerWorkbench\Console\Input;

/** One `workbench <area>` command. Returns the process exit code. */
interface Command
{
    public function run(Input $in): int;
}
