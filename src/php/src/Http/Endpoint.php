<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * One REST collection (list / get / create / update / delete) described once: where it lives, how pages
 * and single objects are wrapped, and which fields to keep. Every write comes back as a PendingAction,
 * so the plan / --dry-run / confirm / audit path is the same for every provider resource.
 *
 * Callers validate ids before they reach a path; the Transport rejects anything unsafe as a backstop.
 */
final readonly class Endpoint
{
    /**
     * @param array<string, string|\Closure(array<mixed>): mixed> $fields    output key => dot path (or closure)
     * @param string|\Closure(array<mixed>): array<mixed>|null    $envelope  key a single object sits under ("droplet",
     *                                                                       "data"), a closure that unwraps it, or null (top level)
     * @param array<string, int|string|bool>                      $listQuery default list query (page size)
     */
    public function __construct(
        private Transport $transport,
        private string $noun,
        private string $path,
        private Paginator $paginator,
        private array $fields,
        private string|\Closure|null $envelope = null,
        private array $listQuery = [],
    ) {}

    public function path(int|string ...$segments): string
    {
        return implode('/', [$this->path, ...array_map(strval(...), $segments)]);
    }

    public function transport(): Transport
    {
        return $this->transport;
    }

    /**
     * @param array<string, int|string|bool> $query
     * @return list<Item>
     */
    public function list(array $query = []): array
    {
        return array_map($this->item(...), $this->rows($query));
    }

    /**
     * Raw rows, for callers that need fields outside the projection.
     *
     * @param array<string, int|string|bool> $query
     * @return list<array<string, mixed>>
     */
    public function rows(array $query = []): array
    {
        return iterator_to_array($this->transport->paginate($this->path, $query + $this->listQuery, $this->paginator), false);
    }

    public function get(int|string $id): Item
    {
        return $this->item($this->unwrap($this->transport->get($this->path(self::id($id)))->json));
    }

    /** @param array<mixed> $row */
    public function item(array $row): Item
    {
        return Item::of($row, $this->fields);
    }

    /**
     * @param array<mixed> $json
     * @return array<mixed>
     */
    public function unwrap(array $json): array
    {
        return match (true) {
            $this->envelope === null => $json,
            $this->envelope instanceof \Closure => ($this->envelope)($json),
            default => Data::map($json, $this->envelope),
        };
    }

    /**
     * @param array<mixed> $body
     * @return PendingAction<Item>
     */
    public function create(array $body, string $target, ?string $note = null, ?string $path = null, bool $destructive = false): PendingAction
    {
        $path ??= $this->path;

        return $this->transport->pending('create '.$this->noun, $target, 'POST', $path, $body,
            fn (): Item => $this->item($this->unwrap($this->transport->send('POST', $path, [], $body)->json)), $destructive, $note);
    }

    /**
     * @param array<mixed> $body
     * @return PendingAction<Item>
     */
    public function update(int|string $id, array $body, string $target, string $method = 'PATCH', ?string $note = null, bool $destructive = false): PendingAction
    {
        $path = $this->path(self::id($id));

        return $this->transport->pending('update '.$this->noun, $target, $method, $path, $body,
            fn (): Item => $this->item($this->unwrap($this->transport->send($method, $path, [], $body)->json)), $destructive, $note);
    }

    /** @return PendingAction<bool> */
    public function delete(int|string $id, ?string $target = null, ?string $note = null): PendingAction
    {
        $path = $this->path(self::id($id));

        return $this->transport->pending('delete '.$this->noun, $target ?? (string) $id, 'DELETE', $path, [],
            fn (): bool => $this->transport->send('DELETE', $path)->status < 300, destructive: true, note: $note);
    }

    /**
     * Any other write on this collection (actions, sub-resources). Returns the decoded response.
     *
     * @param array<mixed>|null $body
     * @return PendingAction<array<mixed>>
     */
    public function call(string $action, string $target, string $method, string $path, ?array $body = [], bool $destructive = false, ?string $note = null): PendingAction
    {
        return $this->transport->pending($action, $target, $method, $path, $body ?? [],
            fn (): array => $this->transport->send($method, $path, [], $body)->json, $destructive, $note);
    }

    /**
     * Nothing to do: the resource is already in the requested state.
     *
     * @return PendingAction<Item>
     */
    public function noop(string $action, string $target, Item $current, ?string $note = null): PendingAction
    {
        return $this->transport->pending($action, $target, 'NONE', $this->path, [], static fn (): Item => $current, note: $note);
    }

    private static function id(int|string $id): string
    {
        return is_int($id) ? (string) Validate::id($id) : Validate::segment($id, 'id');
    }
}
