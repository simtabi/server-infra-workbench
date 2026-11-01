<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/** Cron jobs on a Ploi server. */
final readonly class Crontabs
{
    private Endpoint $api;

    public function __construct(Transport $transport, private int $serverId)
    {
        $this->api = new Endpoint($transport, 'cron job', "/servers/{$serverId}/crontabs", new PloiPaginator, [
            'id' => 'id', 'command' => 'command', 'frequency' => 'frequency', 'user' => 'user', 'status' => 'status',
        ], 'data', ['per_page' => 50]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * Idempotent: the same command, schedule and user is not added twice.
     *
     * @return PendingAction<Item>
     */
    public function create(string $command, string $frequency, string $user = 'ploi'): PendingAction
    {
        $command = trim($command);
        if ($command === '' || strlen($command) > 1000 || preg_match('/[\x00-\x1f\x7f]/', $command) === 1) {
            throw new ValidationException('the cron command must be one printable line (max 1000 characters)');
        }
        $frequency = self::frequency($frequency);
        $user = Validate::token($user, 'system user');
        foreach ($this->list() as $job) {
            if ($job->string('command') === $command && $job->string('frequency') === $frequency && $job->string('user') === $user) {
                return $this->api->noop('create cron job', "\"{$command}\" (already job {$job->int('id')})", $job);
            }
        }

        return $this->api->create(['command' => $command, 'frequency' => $frequency, 'user' => $user], "\"{$frequency} {$command}\" as {$user} on server {$this->serverId}");
    }

    /** @return PendingAction<bool> */
    public function delete(int|string $id): PendingAction
    {
        return $this->api->delete(Validate::id($id, 'cron job id'), "{$id} on server {$this->serverId}", 'the job stops running');
    }

    /** Five cron fields, or a macro (@daily, @hourly ...). */
    public static function frequency(string $frequency): string
    {
        $frequency = trim(preg_replace('/\s+/', ' ', $frequency) ?? '');
        $field = '[0-9*\/,\-A-Za-z]+';
        if (preg_match('/^@(yearly|annually|monthly|weekly|daily|midnight|hourly|reboot)$/', $frequency) !== 1
            && preg_match("/^{$field} {$field} {$field} {$field} {$field}$/", $frequency) !== 1) {
            throw new ValidationException(sprintf('"%s" is not a cron schedule (five fields like "0 3 * * *", or @daily)', substr($frequency, 0, 80)));
        }

        return $frequency;
    }
}
