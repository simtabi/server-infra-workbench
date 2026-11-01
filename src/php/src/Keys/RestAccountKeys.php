<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Keys;

use Simtabi\ServerInfraWorkbench\Exception\NotFoundException;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/** Account SSH keys on any provider described by a KeyApiSpec. */
final readonly class RestAccountKeys implements AccountKeys
{
    public function __construct(private Transport $transport, private KeyApiSpec $spec, private ?string $scope = null) {}

    public function provider(): string
    {
        return $this->spec->name;
    }

    public function list(): array
    {
        $query = match ($this->spec->pagination) {
            'digitalocean' => ['per_page' => 200],
            'cursor' => ['per_page' => 500],
            'hetzner' => ['per_page' => 50],
            'linode', 'scaleway' => ['page_size' => $this->spec->pageSize],
            default => [],
        };
        if ($this->scope !== null && $this->spec->scopeField !== '') {
            $query[$this->spec->scopeField] = $this->scope;
        }
        $out = [];
        foreach ($this->transport->paginate($this->spec->listPath, $query, new KeyPaginator($this->spec->pagination, $this->spec->listField, $this->spec->pageSize)) as $row) {
            $out[] = $this->key($row);
        }

        return $out;
    }

    public function add(string $name, string $publicKey): PendingAction
    {
        $name = Validate::label($name, 'key name');
        $key = PublicKey::parse($publicKey);
        foreach ($this->list() as $existing) {
            if (PublicKey::same($existing->publicKey, $key->line()) || ($existing->fingerprint !== '' && in_array($existing->fingerprint, [$key->md5(), substr($key->md5(), 4), $key->fingerprint()], true))) {
                return $this->transport->pending('add ssh key', "\"{$name}\" (already there as \"{$existing->name}\" [{$existing->id}])", 'NONE', $this->spec->listPath, [], static fn (): SshKey => $existing);
            }
        }
        $path = $this->spec->createPath !== '' ? $this->spec->createPath : $this->spec->listPath;
        $body = [$this->spec->createNameField => $name, $this->spec->createKeyField => $key->line()];
        if ($this->scope !== null && $this->spec->scopeField !== '') {
            $body[$this->spec->scopeField] = $this->scope;
        }

        return $this->transport->pending('add ssh key', "\"{$name}\" ({$key->fingerprint()})", 'POST', $path, $body,
            fn (): SshKey => $this->key($this->item($this->transport->send('POST', $path, [], $body)->json), $name, $key->line()),
            note: 'used for servers created from now on; running servers are not changed');
    }

    public function rename(string $id, string $name): PendingAction
    {
        if ($this->spec->renamePath === '') {
            throw new ValidationException("{$this->spec->name}: rename isn't configured for this provider");
        }
        $name = Validate::label($name, 'key name');
        $current = $this->find($id);
        $path = $this->path($this->spec->renamePath, $id);
        if ($current->name === $name) {
            return $this->transport->pending('rename ssh key', "[{$id}] to \"{$name}\"", 'NONE', $path, [], static fn (): bool => true);
        }
        $method = strtoupper($this->spec->renameMethod);
        $body = [$this->spec->renameField => $name];

        return $this->transport->pending('rename ssh key', "\"{$current->name}\" [{$id}] to \"{$name}\"", $method, $path, $body,
            fn (): bool => $this->transport->send($method, $path, [], $body)->status < 300);
    }

    /** @return PendingAction<bool> */
    public function remove(string $id): PendingAction
    {
        if ($this->spec->deletePath === '') {
            throw new ValidationException("{$this->spec->name}: delete isn't configured for this provider");
        }
        $current = $this->find($id);
        $path = $this->path($this->spec->deletePath, $id);

        return $this->transport->pending('remove ssh key', "\"{$current->name}\" [{$id}]", 'DELETE', $path, [],
            fn (): bool => $this->transport->send('DELETE', $path)->status < 300,
            destructive: true,
            note: 'removes it from the dashboard only: servers that already have this key keep it (see: siwo keys server)');
    }

    public function find(string $id): SshKey
    {
        foreach ($this->list() as $key) {
            if ($key->id === $id) {
                return $key;
            }
        }

        throw new NotFoundException("{$this->spec->name}: no SSH key with id {$id} (see: siwo keys account list --provider {$this->spec->name})");
    }

    private function path(string $template, string $id): string
    {
        return str_replace('{id}', Validate::token($id, 'key id'), $template);
    }

    /**
     * @param array<mixed> $json
     * @return array<string, mixed>
     */
    private function item(array $json): array
    {
        if ($this->spec->itemField === '') {
            $out = [];
            foreach ($json as $k => $v) {
                $out[(string) $k] = $v;
            }

            return $out;
        }

        return Data::map($json, $this->spec->itemField);
    }

    /** @param array<string, mixed> $row */
    private function key(array $row, string $name = '', string $publicKey = ''): SshKey
    {
        $id = Data::get($row, $this->spec->idField);

        return new SshKey(
            $this->spec->name,
            is_int($id) || is_string($id) ? (string) $id : '',
            Data::string($row, $this->spec->nameField, $name),
            Data::string($row, $this->spec->publicKeyField, $publicKey),
            $this->spec->fingerprintField === '' ? '' : Data::string($row, $this->spec->fingerprintField),
        );
    }
}
