<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Security\IssuedCredential;
use Simtabi\VpsServerWorkbench\Security\Secret;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * Databases on a Ploi server. With a user, the password is generated HERE (never typed, never on argv)
 * and handed back as a Secret for a 0600 file: it is sent to Ploi once and never printed.
 */
final readonly class Databases
{
    private Endpoint $api;

    public function __construct(Transport $transport, private int $serverId)
    {
        $this->api = new Endpoint($transport, 'database', "/servers/{$serverId}/databases", new PloiPaginator, [
            'id' => 'id', 'name' => 'name', 'type' => 'type', 'siteId' => 'site_id', 'status' => 'status', 'createdAt' => 'created_at',
        ], 'data', ['per_page' => 50]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * @return PendingAction<IssuedCredential|Item> an IssuedCredential holding the generated password when a user is created, else the database
     */
    public function create(string $name, ?string $user = null, ?int $siteId = null, string $description = ''): PendingAction
    {
        $name = self::identifier($name, 'database name');
        $user = $user === null ? null : self::identifier($user, 'database user');
        foreach ($this->list() as $db) {
            if ($db->string('name') === $name) {
                throw new ValidationException(sprintf('database "%s" already exists on server %d (id %d)', $name, $this->serverId, $db->int('id')));
            }
        }
        $password = $user === null ? null : new Secret(self::password());
        $plan = array_filter(['name' => $name, 'user' => $user, 'password' => $user === null ? null : '(generated locally)',
            'description' => $description === '' ? null : Validate::label($description, 'description'), 'site_id' => $siteId === null ? null : Validate::id($siteId, 'site id')],
            static fn (mixed $v): bool => $v !== null);
        $transport = $this->api->transport();
        $path = $this->api->path();

        return $transport->pending('create database', "\"{$name}\"".($user !== null ? " with user {$user}" : '')." on server {$this->serverId}", 'POST', $path, $plan,
            function () use ($transport, $path, $plan, $password): IssuedCredential|Item {
                $body = $password === null ? $plan : ['password' => $password->reveal()] + $plan;
                $database = $this->api->item(Data::map($transport->send('POST', $path, [], $body)->json, 'data'));

                return $password === null ? $database : new IssuedCredential($database, $password);
            }, note: $user === null ? null : 'the generated password is written to the --out file (chmod 600), never printed');
    }

    /**
     * Destructive: the data is gone.
     *
     * @return PendingAction<bool>
     */
    public function delete(int|string $id): PendingAction
    {
        return $this->api->delete(Validate::id($id, 'database id'), "{$id} on server {$this->serverId}", 'every table and row is dropped; back it up first');
    }

    /** 32 characters from a URL- and shell-safe alphabet: no quoting problems in .env files. */
    public static function password(int $length = 32): string
    {
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
        $out = '';
        for ($i = 0; $i < $length; $i++) {
            $out .= $alphabet[random_int(0, strlen($alphabet) - 1)];
        }

        return $out;
    }

    private static function identifier(string $value, string $what): string
    {
        if (preg_match('/^[A-Za-z_][A-Za-z0-9_]{0,63}$/', $value) !== 1) {
            throw new ValidationException(sprintf('%s "%s" may only contain letters, digits and _ (max 64, not starting with a digit)', $what, substr($value, 0, 80)));
        }

        return $value;
    }
}
