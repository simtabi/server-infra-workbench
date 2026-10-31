<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Keys;

use Simtabi\VpsServerWorkbench\Safety\PendingAction;

/** The four operations every provider supports for dashboard SSH keys. */
interface AccountKeys
{
    public function provider(): string;

    /** @return list<SshKey> */
    public function list(): array;

    /** @return PendingAction<SshKey> a no-op when the same key material is already on the account */
    public function add(string $name, string $publicKey): PendingAction;

    /** @return PendingAction<bool> */
    public function rename(string $id, string $name): PendingAction;

    /**
     * Destructive. Servers that already have the key keep it.
     *
     * @return PendingAction<bool>
     */
    public function remove(string $id): PendingAction;
}
