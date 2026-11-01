<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Ploi;

use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Ploi\Data\Server;
use Simtabi\ServerInfraWorkbench\Support\Validate;

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
