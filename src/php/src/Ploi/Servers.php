<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi;

use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Ploi\Data\Server;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Servers
{
    public function __construct(private Transport $transport) {}

    /** @return list<Server> */
    public function list(): array
    {
        $out = [];
        foreach ($this->transport->paginate('/servers', ['per_page' => 50], new PloiPaginator) as $row) {
            $out[] = Server::fromArray($row);
        }

        return $out;
    }

    /** A handle scoped to one server. No request is made until you call something on it. */
    public function find(int|string $id): ServerResource
    {
        return new ServerResource($this->transport, Validate::id($id, 'server id'));
    }

    public function get(int|string $id): Server
    {
        return $this->find($id)->get();
    }
}
