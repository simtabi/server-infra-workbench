<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Keys;

use Simtabi\ServerInfraWorkbench\Exception\TransportException;

/**
 * The system ssh, so ~/.ssh/config, the agent and known_hosts all apply. BatchMode means a failed key
 * login fails fast instead of hanging on a password prompt. No shell is involved on this side.
 */
final readonly class ProcessSshRunner implements SshRunner
{
    public function __construct(private int $connectTimeout = 15, private int $timeout = 60, private string $ssh = 'ssh') {}

    public function run(string $target, array $options, string $command, ?string $stdin = null): array
    {
        $cmd = [$this->ssh, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout='.$this->connectTimeout, ...$options, '--', $target, $command];
        $proc = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (! is_resource($proc)) {
            throw new TransportException('ssh is not installed or not on PATH');
        }
        fwrite($pipes[0], $stdin ?? '');
        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $out = $err = '';
        $deadline = microtime(true) + $this->timeout;
        while (true) {
            $out .= (string) stream_get_contents($pipes[1]);
            $err .= (string) stream_get_contents($pipes[2]);
            $status = proc_get_status($proc);
            if (! $status['running']) {
                $out .= (string) stream_get_contents($pipes[1]);
                $err .= (string) stream_get_contents($pipes[2]);
                fclose($pipes[1]);
                fclose($pipes[2]);
                proc_close($proc);

                return ['exit' => $status['exitcode'], 'stdout' => $out, 'stderr' => $err];
            }
            if (microtime(true) > $deadline) {
                proc_terminate($proc);
                proc_close($proc);

                throw new TransportException("ssh to {$target} timed out");
            }
            usleep(20_000);
        }
    }
}
