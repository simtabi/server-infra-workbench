<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Ploi;

use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Ploi\Data\Server;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

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

    public function crontabs(): Crontabs
    {
        return new Crontabs($this->transport, $this->id);
    }

    public function databases(): Databases
    {
        return new Databases($this->transport, $this->id);
    }

    public function certificates(int|string $siteId): Certificates
    {
        return new Certificates($this->transport, $this->id, Validate::id($siteId, 'site id'));
    }

    /**
     * Reboots the server: every site on it is down for a minute or two.
     *
     * @return PendingAction<bool>
     */
    public function restart(): PendingAction
    {
        $path = "/servers/{$this->id}/restart";

        return $this->transport->pending('restart server', (string) $this->id, 'POST', $path, [],
            fn (): bool => $this->transport->send('POST', $path)->status < 300, true, 'every site on the server is down until it is back up');
    }

    public function sites(): Sites
    {
        return new Sites($this->transport, $this->id);
    }
}
