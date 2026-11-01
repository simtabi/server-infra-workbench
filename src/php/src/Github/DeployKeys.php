<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Github;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * Deploy keys: an SSH key that can pull (and, only if asked, push) ONE repository. The usual way for a
 * server to `git pull` its app. Read-only by default.
 */
final readonly class DeployKeys
{
    private Endpoint $api;

    public function __construct(Transport $transport, private Repository $repo)
    {
        $this->api = new Endpoint($transport, 'deploy key', $repo->path('keys'), new GithubPaginator,
            ['id' => 'id', 'title' => 'title', 'readOnly' => 'read_only', 'verified' => 'verified', 'createdAt' => 'created_at', 'lastUsed' => 'last_used'],
            null, ['per_page' => 100]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * Idempotent by key material. A key with write access is destructive (it can rewrite history).
     *
     * @return PendingAction<Item>
     */
    public function add(string $title, string $publicKey, bool $readOnly = true): PendingAction
    {
        $title = Validate::label($title, 'title', 100);
        $publicKey = trim($publicKey);
        if (preg_match('/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) [A-Za-z0-9+\/=]{40,}( .*)?$/', $publicKey) !== 1) {
            throw new ValidationException('that is not an OpenSSH public key (ssh-ed25519 AAAA...); never pass a private key');
        }
        $material = implode(' ', array_slice(explode(' ', $publicKey), 0, 2));
        foreach ($this->api->rows() as $row) {
            if (str_starts_with(Data::string($row, 'key'), $material)) {
                return $this->api->noop('add deploy key', sprintf('"%s" (already key %d)', $title, Data::int($row, 'id')), $this->api->item($row));
            }
        }

        return $this->api->create(['title' => $title, 'key' => $material, 'read_only' => $readOnly], "\"{$title}\" on {$this->repo}".($readOnly ? ' (read-only)' : ' (READ-WRITE)'),
            $readOnly ? null : 'a write key can push to (and force-push over) every branch it is not protected from', destructive: ! $readOnly);
    }

    /** @return PendingAction<bool> */
    public function delete(int|string $id): PendingAction
    {
        return $this->api->delete(Validate::id($id, 'deploy key id'), "{$id} on {$this->repo}", 'servers using it can no longer pull');
    }
}
