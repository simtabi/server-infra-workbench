<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Ploi;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Ploi\Data\Daemon;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

final readonly class Daemons
{
    public function __construct(private Transport $transport, private int $serverId) {}

    /** @return list<Daemon> */
    public function list(): array
    {
        $out = [];
        foreach ($this->transport->paginate("/servers/{$this->serverId}/daemons", ['per_page' => 50], new PloiPaginator) as $row) {
            $out[] = Daemon::fromArray($row);
        }

        return $out;
    }

    /**
     * Idempotent: the same command for the same user is not added twice.
     *
     * @return PendingAction<Daemon>
     */
    public function create(string $command, string $systemUser = 'ploi', int $processes = 1, string $directory = ''): PendingAction
    {
        $command = trim($command);
        if ($command === '' || strlen($command) > 1000 || preg_match('/[\x00-\x1f\x7f]/', $command) === 1) {
            throw new ValidationException('the daemon command must be one printable line (max 1000 characters)');
        }
        $systemUser = Validate::token($systemUser, 'system user');
        $processes = Validate::range($processes, 1, 32, 'processes');
        if ($directory !== '' && (preg_match('#^/[A-Za-z0-9/_.-]*$#', $directory) !== 1 || str_contains($directory, '..'))) {
            throw new ValidationException(sprintf('directory "%s" must be an absolute path', $directory));
        }
        $path = "/servers/{$this->serverId}/daemons";
        foreach ($this->list() as $daemon) {
            if ($daemon->command === $command && $daemon->systemUser === $systemUser) {
                return $this->transport->pending('create daemon', "\"{$command}\" (already daemon {$daemon->id})", 'NONE', $path, [], static fn (): Daemon => $daemon);
            }
        }
        $body = array_filter(['command' => $command, 'system_user' => $systemUser, 'processes' => $processes, 'directory' => $directory], static fn (int|string $v): bool => $v !== '');

        return $this->transport->pending('create daemon', "\"{$command}\" x{$processes} as {$systemUser} on server {$this->serverId}", 'POST', $path, $body,
            fn (): Daemon => Daemon::fromArray(Data::map($this->transport->send('POST', $path, [], $body)->json, 'data')),
            note: 'supervisor starts it immediately and restarts it if it exits');
    }

    /** @return PendingAction<bool> */
    public function delete(int|string $daemonId): PendingAction
    {
        $daemonId = Validate::id($daemonId, 'daemon id');
        $path = "/servers/{$this->serverId}/daemons/{$daemonId}";

        return $this->transport->pending('delete daemon', "{$daemonId} on server {$this->serverId}", 'DELETE', $path, [],
            fn (): bool => $this->transport->send('DELETE', $path)->status < 300,
            destructive: true, note: 'stops the process');
    }
}
