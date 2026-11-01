<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Fixtures;

use Simtabi\ServerInfraWorkbench\Keys\SshRunner;

/** A pretend server: one authorized_keys file, backups, and scripted ssh behaviour. No processes run. */
final class FakeSshRunner implements SshRunner
{
    public string $file = '';

    /** @var array<string, string> */
    public array $backups = [];

    public ?string $sessionFingerprint = null;

    public int $freshLoginExit = 0;

    public bool $corruptWrite = false;

    public bool $permsFixed = false;

    /** @var list<array{options: list<string>, command: string}> */
    public array $calls = [];

    public function run(string $target, array $options, string $command, ?string $stdin = null): array
    {
        $this->calls[] = ['options' => $options, 'command' => $command];
        $ok = static fn (string $out = ''): array => ['exit' => 0, 'stdout' => $out, 'stderr' => ''];
        if (in_array('-v', $options, true)) {
            return ['exit' => 0, 'stdout' => '', 'stderr' => $this->sessionFingerprint === null ? "debug1: Authenticated using \"publickey\"\n"
                : "debug1: Offering public key: /home/me/.ssh/id_ed25519 ED25519 {$this->sessionFingerprint} agent\ndebug1: Server accepts key: /home/me/.ssh/id_ed25519 ED25519 {$this->sessionFingerprint} agent\n"];
        }
        if (in_array('ControlPath=none', $options, true)) {
            return ['exit' => $this->freshLoginExit, 'stdout' => '', 'stderr' => $this->freshLoginExit === 0 ? '' : 'Permission denied (publickey).'];
        }
        if (str_starts_with($command, 'cat ~/.ssh/authorized_keys ')) {
            return $ok($this->file);
        }
        if (str_contains($command, 'cat > ~/.ssh/authorized_keys.new')) {
            $name = preg_match('/authorized_keys\.bak\.[0-9-]+/', $command, $m) === 1 ? $m[0] : 'unknown';
            $this->backups[$name] = $this->file;
            $this->file = $this->corruptWrite ? 'garbage' : (string) $stdin;

            return $ok();
        }
        if (preg_match('#^cp -p ~/\.ssh/(authorized_keys\.bak\.[0-9-]+) ~/\.ssh/authorized_keys$#', $command, $m) === 1) {
            $this->file = $this->backups[$m[1]];

            return $ok();
        }
        if (str_contains($command, 'chmod 600')) {
            $this->permsFixed = true;

            return $ok();
        }
        if ($command === 'true') {
            return $ok();
        }

        return ['exit' => 127, 'stdout' => '', 'stderr' => 'unexpected command: '.$command];
    }

    /** @return list<string> */
    public function commands(): array
    {
        return array_map(static fn (array $c): string => $c['command'], $this->calls);
    }
}
