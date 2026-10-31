<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Keys;

/** Runs `ssh <options> <target> <command>`. Tests use a fake; ProcessSshRunner runs the system ssh. */
interface SshRunner
{
    /**
     * @param list<string> $options extra ssh options, e.g. ['-p', '2222', '-o', 'ControlPath=...']
     * @return array{exit: int, stdout: string, stderr: string}
     */
    public function run(string $target, array $options, string $command, ?string $stdin = null): array;
}
