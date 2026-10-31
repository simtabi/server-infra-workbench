<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi;

use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Ploi\Data\Server;
use Simtabi\VpsServerWorkbench\Support\Data;

final readonly class ServerResource
{
    public function __construct(private Transport $transport, private int $id) {}

    public function id(): int
    {
        return $this->id;
    }

    public function get(): Server
    {
        return Server::fromArray(Data::map($this->transport->get("/servers/{$this->id}")->json, 'data'));
    }

    public function daemons(): Daemons
    {
        return new Daemons($this->transport, $this->id);
    }

    public function sites(): Sites
    {
        return new Sites($this->transport, $this->id);
    }
}
